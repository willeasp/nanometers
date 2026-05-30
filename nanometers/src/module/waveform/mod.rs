//! Waveform Module (ADRs 0001 / 0007 + `docs/specs/waveform-module.md`).
//!
//! A scrolling amplitude-envelope view: per channel, a filled min/max contour, newest sample at
//! the right edge. Replaces the fake glow on the Oscilloscope (0007). Built in milestones (spec §9):
//! M1 here is the mono, monochrome, scrolling contour fill on a fixed window.
//!
//! Threading: samples fold into 0.5 ms base bins in `update`; the per-column triangle-strip geometry
//! is (re)built in `prepare` (which gets the viewport width → column count) and uploaded; `render`
//! draws it. The host sets viewport+scissor, so geometry is emitted in plain [-1, 1] clip space.

pub mod color;
pub mod store;

use bytemuck::{Pod, Zeroable};
use std::borrow::Cow;
use wgpu::util::DeviceExt;

use super::{EventStatus, FrameContext, Module, Rect};
use color::{Filterbank, band_color};
use store::{BaseBin, ChannelEnvelope, merge};

/// Base-bin width (ADR 0002). Sample-rate-independent: 0.5 ms → 2000 bins/sec.
const BIN_SECONDS: f32 = 0.0005;
/// 3-band filterbank crossovers (ADR 0001; dev-player tuning later, spec §6/§10).
const BAND_LOW_HZ: f32 = 250.0;
const BAND_HIGH_HZ: f32 = 4000.0;
/// Default viewable window (spec §6 — Module config later).
const DEFAULT_WINDOW_SECONDS: f32 = 5.0;
/// Per-half amplitude scale. Each channel occupies half the column height (L top, R bottom,
/// centered at clip y ±0.5); sample ±1 reaches ±0.45 within its half, leaving a small margin.
const HALF_SCALE: f32 = 0.45;
/// Clip-y center of each channel's half: L = +0.5 (top), R = −0.5 (bottom).
const HALF_CENTER: [f32; 2] = [0.5, -0.5];
/// Cap on columns built per frame (≈ one per pixel; the window is rarely wider).
const MAX_COLUMNS: usize = 2048;
/// Gentle global desaturation: mix each column color this far toward white (ADR 0001 dev-tuning).
/// 0 = full saturation, 1 = white. Softens the palette without changing hues.
const COLOR_WHITE_MIX: f32 = 0.18;

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 3],
}

pub struct WaveformModule {
    // The viewable window is captured as the ring length (`bins.len()`). The `window_seconds`
    // config value + persistence land in Phase F (spec §6).

    // Derived from the host sample rate; 0 until the first non-zero `FrameContext::sample_rate`.
    sample_rate: f32,
    samples_per_bin: usize,

    // 3-band filterbank on the mono sum (ADR 0001), rebuilt when the sample rate changes.
    filterbank: Option<Filterbank>,

    // Fixed-length ring of base bins (length = window_seconds / 0.5 ms, sample-rate-independent).
    // `bins_closed` is the monotonic total ever closed; the ring slot for absolute bin `a` is
    // `a % bins.len()`. Display columns are anchored to ABSOLUTE bin boundaries (see `prepare`) so
    // a column's value is frozen once computed — that's what kills the scroll jitter.
    bins: Vec<BaseBin>,
    bins_closed: u64,

    // In-progress base bin accumulator (per channel: min/max/Σsquares + a sample counter).
    acc_min: [f32; 2],
    acc_max: [f32; 2],
    acc_sumsq: [f32; 2],
    acc_band_sumsq: [f32; 3],
    acc_count: usize,

    // Per-frame scratch reused to avoid allocation.
    linear: Vec<BaseBin>,
    verts: Vec<Vertex>,

    pipeline: wgpu::RenderPipeline,
    // L contour occupies [0, count_l) of the buffer, R contour the next `count_r` vertices.
    vertex_buffer: wgpu::Buffer,
    vertex_count_l: u32,
    vertex_count_r: u32,
}

impl WaveformModule {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        Self::with_window(device, format, DEFAULT_WINDOW_SECONDS)
    }

    pub fn with_window(
        device: &wgpu::Device,
        format: wgpu::TextureFormat,
        window_seconds: f32,
    ) -> Self {
        let window_bins = (window_seconds / BIN_SECONDS).round().max(1.0) as usize;

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("waveform-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(CONTOUR_WGSL)),
        });

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("waveform-pl"),
            bind_group_layouts: &[],
            immediate_size: 0,
        });

        let vertex_layout = wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute {
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x2,
                    offset: 0,
                },
                wgpu::VertexAttribute {
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x3,
                    offset: std::mem::size_of::<[f32; 2]>() as u64,
                },
            ],
        };

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("waveform-pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[vertex_layout],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None, // opaque fill over the cleared background
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        // 2 vertices per column per channel (top/bottom curve, L + R), capped at MAX_COLUMNS.
        let vbuf_bytes = (4 * MAX_COLUMNS * std::mem::size_of::<Vertex>()) as u64;
        let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("waveform-vbuf"),
            contents: &vec![0u8; vbuf_bytes as usize],
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        });

        Self {
            sample_rate: 0.0,
            samples_per_bin: 0,
            filterbank: None,
            bins: vec![BaseBin::SILENCE; window_bins],
            bins_closed: 0,
            acc_min: [f32::INFINITY; 2],
            acc_max: [f32::NEG_INFINITY; 2],
            acc_sumsq: [0.0; 2],
            acc_band_sumsq: [0.0; 3],
            acc_count: 0,
            linear: vec![BaseBin::SILENCE; window_bins],
            verts: Vec::with_capacity(4 * MAX_COLUMNS),
            pipeline,
            vertex_buffer,
            vertex_count_l: 0,
            vertex_count_r: 0,
        }
    }

    fn reset_accumulator(&mut self) {
        self.acc_min = [f32::INFINITY; 2];
        self.acc_max = [f32::NEG_INFINITY; 2];
        self.acc_sumsq = [0.0; 2];
        self.acc_band_sumsq = [0.0; 3];
        self.acc_count = 0;
    }

    fn close_bin(&mut self) {
        let n = self.acc_count.max(1) as f32;
        let env = [
            ChannelEnvelope {
                min: self.acc_min[0],
                max: self.acc_max[0],
                mean_square: self.acc_sumsq[0] / n,
            },
            ChannelEnvelope {
                min: self.acc_min[1],
                max: self.acc_max[1],
                mean_square: self.acc_sumsq[1] / n,
            },
        ];
        let band_ms = [
            self.acc_band_sumsq[0] / n,
            self.acc_band_sumsq[1] / n,
            self.acc_band_sumsq[2] / n,
        ];
        let pos = (self.bins_closed % self.bins.len() as u64) as usize;
        self.bins[pos] = BaseBin { env, band_ms };
        self.bins_closed = self.bins_closed.wrapping_add(1);
        self.reset_accumulator();
    }
}

impl Module for WaveformModule {
    fn update(&mut self, ctx: &FrameContext, _queue: &wgpu::Queue) {
        if ctx.sample_rate <= 0.0 {
            return; // unknown rate — idle (spec)
        }
        if ctx.sample_rate != self.sample_rate {
            self.sample_rate = ctx.sample_rate;
            self.samples_per_bin = (ctx.sample_rate * BIN_SECONDS).round().max(1.0) as usize;
            self.filterbank = Some(Filterbank::new(ctx.sample_rate, BAND_LOW_HZ, BAND_HIGH_HZ));
            self.reset_accumulator();
        }

        for &[l, r] in ctx.new {
            // Spectral color (ADR 0001): filter the mono sum, accumulate per-band power. The
            // `as_mut` borrow ends before the envelope fold / close_bin touch the rest of `self`.
            let mono = 0.5 * (l + r);
            let bands = self
                .filterbank
                .as_mut()
                .map(|fb| fb.process(mono))
                .unwrap_or([0.0; 3]);

            self.acc_min[0] = self.acc_min[0].min(l);
            self.acc_max[0] = self.acc_max[0].max(l);
            self.acc_sumsq[0] += l * l;
            self.acc_min[1] = self.acc_min[1].min(r);
            self.acc_max[1] = self.acc_max[1].max(r);
            self.acc_sumsq[1] += r * r;
            for k in 0..3 {
                self.acc_band_sumsq[k] += bands[k] * bands[k];
            }
            self.acc_count += 1;
            if self.acc_count >= self.samples_per_bin {
                self.close_bin();
            }
        }
    }

    fn prepare(
        &mut self,
        _device: &wgpu::Device,
        queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
    ) {
        if self.samples_per_bin == 0 {
            self.vertex_count_l = 0;
            self.vertex_count_r = 0;
            return;
        }

        // Linearize the ring oldest→newest: `linear[i]` holds absolute bin `(total - n + i)`.
        let n = self.bins.len();
        let total = self.bins_closed;
        let head = (total % n as u64) as usize;
        for i in 0..n {
            self.linear[i] = self.bins[(head + i) % n];
        }

        let columns = (viewport.w.round() as usize).clamp(1, MAX_COLUMNS);
        let denom = (columns.max(2) - 1) as f32;
        self.verts.clear();

        // Anchor columns to ABSOLUTE bin boundaries (multiples of `bpc`) instead of re-dividing the
        // sliding window each frame. A column covers a fixed absolute bin range, so its merged
        // value is identical frame-to-frame until it scrolls off — no per-frame re-merge jitter.
        // The whole grid shifts left by whole columns as new boundaries complete (smooth scroll).
        let bpc = (n / columns).max(1) as i128; // base bins per display column
        let win_start = total as i128 - n as i128; // oldest absolute bin still in the ring
        let last_boundary = ((total as i128) / bpc) * bpc; // right edge, bpc-aligned

        // Pre-merge one column per screen position (shared by both channels — same bins).
        let mut col_bins: Vec<BaseBin> = Vec::with_capacity(columns);
        for c in 0..columns {
            let end_abs = last_boundary - ((columns - 1 - c) as i128) * bpc;
            let start_abs = end_abs - bpc;
            let lo = start_abs.max(win_start);
            let hi = end_abs.min(total as i128);
            col_bins.push(if lo < hi {
                merge(&self.linear[(lo - win_start) as usize..(hi - win_start) as usize])
            } else {
                BaseBin::SILENCE
            });
        }

        // One triangle strip per channel: L top half (center +0.5), R bottom half (−0.5) — spec §4.
        for ch in 0..2 {
            for (c, merged) in col_bins.iter().enumerate() {
                let env = merged.env[ch];
                // One color per column from the shared (mono) band energies (ADR 0001), softened
                // toward white; interpolated along time by the rasterizer.
                let hue = band_color(merged.band_ms);
                let color = [
                    hue[0] + (1.0 - hue[0]) * COLOR_WHITE_MIX,
                    hue[1] + (1.0 - hue[1]) * COLOR_WHITE_MIX,
                    hue[2] + (1.0 - hue[2]) * COLOR_WHITE_MIX,
                ];
                let x = -1.0 + 2.0 * (c as f32) / denom;
                let center = HALF_CENTER[ch];
                self.verts.push(Vertex { pos: [x, center + env.max * HALF_SCALE], color });
                self.verts.push(Vertex { pos: [x, center + env.min * HALF_SCALE], color });
            }
        }

        queue.write_buffer(&self.vertex_buffer, 0, bytemuck::cast_slice(&self.verts));
        self.vertex_count_l = (2 * columns) as u32;
        self.vertex_count_r = (2 * columns) as u32;
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        if self.vertex_count_l == 0 {
            return;
        }
        rpass.set_pipeline(&self.pipeline);
        rpass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
        // L strip, then R strip — separate draws so the top/bottom contours stay disjoint.
        rpass.draw(0..self.vertex_count_l, 0..1);
        rpass.draw(self.vertex_count_l..(self.vertex_count_l + self.vertex_count_r), 0..1);
    }

    fn on_event(&mut self, _event: &baseview::Event, _viewport: Rect) -> EventStatus {
        EventStatus::Ignored
    }

    fn save_config(&self) -> Vec<u8> {
        Vec::new() // opaque config lands in Phase F
    }

    fn load_config(&mut self, _bytes: &[u8]) {}
}

const CONTOUR_WGSL: &str = r#"
struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) color: vec3<f32>,
};

@vertex
fn vs_main(@location(0) pos: vec2<f32>, @location(1) color: vec3<f32>) -> VsOut {
    var o: VsOut;
    o.clip = vec4<f32>(pos, 0.0, 1.0);
    o.color = color;
    return o;
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    // Per-column spectral color (ADR 0001), interpolated along time by the rasterizer.
    return vec4<f32>(in.color, 1.0);
}
"#;
