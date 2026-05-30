//! Waveform Module (ADRs 0001 / 0007 + `docs/specs/waveform-module.md`).
//!
//! A scrolling amplitude-envelope view: per channel, a filled min/max contour, newest sample at
//! the right edge. Replaces the fake glow on the Oscilloscope (0007). Built in milestones (spec §9):
//! M1 here is the mono, monochrome, scrolling contour fill on a fixed window.
//!
//! Threading: samples fold into 0.5 ms base bins in `update`; the per-column triangle-strip geometry
//! is (re)built in `prepare` (which gets the viewport width → column count) and uploaded; `render`
//! draws it. The host sets viewport+scissor, so geometry is emitted in plain [-1, 1] clip space.

pub mod store;

use bytemuck::{Pod, Zeroable};
use std::borrow::Cow;
use wgpu::util::DeviceExt;

use super::{EventStatus, FrameContext, Module, Rect};
use store::{BaseBin, ChannelEnvelope, merge};

/// Base-bin width (ADR 0002). Sample-rate-independent: 0.5 ms → 2000 bins/sec.
const BIN_SECONDS: f32 = 0.0005;
/// Default viewable window (spec §6 — Module config later).
const DEFAULT_WINDOW_SECONDS: f32 = 5.0;
/// Vertical amplitude scale: sample ±1 reaches clip y ±0.9, leaving a small margin.
const Y_SCALE: f32 = 0.9;
/// Cap on columns built per frame (≈ one per pixel; the window is rarely wider).
const MAX_COLUMNS: usize = 2048;

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
}

pub struct WaveformModule {
    // The viewable window is captured as the ring length (`bins.len()`). The `window_seconds`
    // config value + persistence land in Phase F (spec §6).

    // Derived from the host sample rate; 0 until the first non-zero `FrameContext::sample_rate`.
    sample_rate: f32,
    samples_per_bin: usize,

    // Fixed-length ring of base bins (length = window_seconds / 0.5 ms, sample-rate-independent),
    // newest at `write_head - 1`. Pre-filled with silence so an unfilled window reads as flat.
    bins: Vec<BaseBin>,
    write_head: usize,

    // In-progress base bin accumulator (per channel: min/max/Σsquares + a sample counter).
    acc_min: [f32; 2],
    acc_max: [f32; 2],
    acc_sumsq: [f32; 2],
    acc_count: usize,

    // Per-frame scratch reused to avoid allocation.
    linear: Vec<BaseBin>,
    verts: Vec<Vertex>,

    pipeline: wgpu::RenderPipeline,
    vertex_buffer: wgpu::Buffer,
    vertex_count: u32,
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
            attributes: &[wgpu::VertexAttribute {
                shader_location: 0,
                format: wgpu::VertexFormat::Float32x2,
                offset: 0,
            }],
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

        // 2 vertices per column (top/bottom curve), capped at MAX_COLUMNS.
        let vbuf_bytes = (2 * MAX_COLUMNS * std::mem::size_of::<Vertex>()) as u64;
        let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("waveform-vbuf"),
            contents: &vec![0u8; vbuf_bytes as usize],
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        });

        Self {
            sample_rate: 0.0,
            samples_per_bin: 0,
            bins: vec![BaseBin::SILENCE; window_bins],
            write_head: 0,
            acc_min: [f32::INFINITY; 2],
            acc_max: [f32::NEG_INFINITY; 2],
            acc_sumsq: [0.0; 2],
            acc_count: 0,
            linear: vec![BaseBin::SILENCE; window_bins],
            verts: Vec::with_capacity(2 * MAX_COLUMNS),
            pipeline,
            vertex_buffer,
            vertex_count: 0,
        }
    }

    fn reset_accumulator(&mut self) {
        self.acc_min = [f32::INFINITY; 2];
        self.acc_max = [f32::NEG_INFINITY; 2];
        self.acc_sumsq = [0.0; 2];
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
        // band_ms stays 0 until the filterbank (C4 / spec §3.2).
        self.bins[self.write_head] = BaseBin { env, band_ms: [0.0; 3] };
        self.write_head = (self.write_head + 1) % self.bins.len();
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
            self.reset_accumulator();
        }

        for &[l, r] in ctx.new {
            self.acc_min[0] = self.acc_min[0].min(l);
            self.acc_max[0] = self.acc_max[0].max(l);
            self.acc_sumsq[0] += l * l;
            self.acc_min[1] = self.acc_min[1].min(r);
            self.acc_max[1] = self.acc_max[1].max(r);
            self.acc_sumsq[1] += r * r;
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
            self.vertex_count = 0;
            return;
        }

        // Linearize the ring oldest→newest so column ranges are contiguous.
        let n = self.bins.len();
        let head = self.write_head;
        for i in 0..n {
            self.linear[i] = self.bins[(head + i) % n];
        }

        let columns = (viewport.w.round() as usize).clamp(1, MAX_COLUMNS);
        self.verts.clear();
        let denom = (columns.max(2) - 1) as f32;
        for c in 0..columns {
            let lo = c * n / columns;
            let hi = (((c + 1) * n / columns).max(lo + 1)).min(n);
            let m = merge(&self.linear[lo..hi]);
            // M1: mono contour — combine L and R into one full-height silhouette.
            let top = m.env[0].max.max(m.env[1].max);
            let bot = m.env[0].min.min(m.env[1].min);
            let x = -1.0 + 2.0 * (c as f32) / denom;
            self.verts.push(Vertex { pos: [x, top * Y_SCALE] });
            self.verts.push(Vertex { pos: [x, bot * Y_SCALE] });
        }

        queue.write_buffer(&self.vertex_buffer, 0, bytemuck::cast_slice(&self.verts));
        self.vertex_count = self.verts.len() as u32;
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        if self.vertex_count == 0 {
            return;
        }
        rpass.set_pipeline(&self.pipeline);
        rpass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
        rpass.draw(0..self.vertex_count, 0..1);
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
struct VsOut { @builtin(position) clip: vec4<f32> };

@vertex
fn vs_main(@location(0) pos: vec2<f32>) -> VsOut {
    var o: VsOut;
    o.clip = vec4<f32>(pos, 0.0, 1.0);
    return o;
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
    // M1 monochrome teal fill. Spectral color comes in M3 (filterbank, ADR 0001).
    return vec4<f32>(0.30, 0.72, 0.82, 1.0);
}
"#;
