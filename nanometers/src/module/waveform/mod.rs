//! Waveform Module (ADRs 0001 / 0007 + `docs/specs/waveform-module.md`).
//!
//! A scrolling amplitude-envelope view: per channel, a filled min/max contour, spectrally colored,
//! newest sample at the right edge. Replaces the fake glow on the Oscilloscope (0007).
//!
//! Scroll (the "subway sign" model — uniform integer-pixel movement):
//! the contour moves by a FIXED integer number of pixels every display frame, paced by the frame
//! clock, NOT by how many samples drained that frame (whose ±20% jitter was the source of the
//! micro-jumping). Each column is sized to an exact span of samples derived from the refresh rate —
//! `samples_per_col = sample_rate / (px_per_frame · fps)` — so the audio produces columns at exactly
//! the rate the display consumes them: no drift, and every frame is an identical clean pixel shift.
//! No sub-pixel interpolation → crisp 1px columns, no transient brightness pulse.
//!
//! Split of concerns: [`store::WaveStore`] owns the GPU-free base-bin store + sample-anchored column
//! building (unit-tested). The contour renders into an own 4× MSAA offscreen (0007) for edge AA,
//! resolved and composited 1:1 into the column.

use bytemuck::{Pod, Zeroable};
use std::borrow::Cow;
use std::collections::VecDeque;
use std::time::Instant;
use wgpu::util::DeviceExt;

use super::{EventStatus, FrameContext, Module, Rect};
// The Waveform's GPU-free core now lives in `nano-dsp` (ADR 0008): the base-bin store, the spectral
// color mapping, and the scroll control law. This module is the thin wgpu wrapper over them.
use nano_dsp::waveform::color::band_color;
use nano_dsp::waveform::store::{self, WaveStore};
use nano_dsp::waveform::{choose_px_per_frame, consume_samples};

/// 3-band filterbank crossovers (ADR 0001; dev-player tuning later, spec §6/§10).
const BAND_LOW_HZ: f32 = 250.0;
const BAND_HIGH_HZ: f32 = 4000.0;
/// Viewable window the display spans (spec §6 — Module config later).
const DISPLAY_WINDOW_SECONDS: f64 = 5.0;
/// The base-bin store holds more than the display window so the left edge never clips.
const STORE_WINDOW_SECONDS: f32 = 8.0;
/// Per-half amplitude scale: L top half (clip-y center +0.5), R bottom half (−0.5); sample ±1
/// reaches ±0.45 within its half.
const HALF_SCALE: f32 = 0.45;
const HALF_CENTER: [f32; 2] = [0.5, -0.5];
/// Cap on display columns (≈ one per pixel; the window is rarely wider).
const MAX_COLUMNS: usize = 4096;
/// Gentle global desaturation: mix each column color this far toward white (ADR 0001 dev-tuning).
const COLOR_WHITE_MIX: f32 = 0.18;
/// MSAA sample count for the Waveform's own offscreen target (0007 — host pass stays single-sample).
const MSAA_SAMPLES: u32 = 4;

/// No new closed audio for longer than this → paused; freeze the scroll. Loose enough that ordinary
/// bursty arrival (a couple of audio blocks) isn't mistaken for a pause.
const PAUSE_SECONDS: f64 = 0.07;
/// Floor on samples-per-column (a column must hold at least one base bin's worth).
const MIN_SAMPLES_PER_COL: f64 = 1.0;
/// EMA weight for the measured per-frame arrival (samples closed per render). Drives the nominal
/// consume rate + the integer pixel step. Slow → a smooth, near-constant per-pixel sample count.
const ARRIVAL_BETA: f64 = 0.01;
/// Proportional gain of the reservoir control loop: how hard we slew the per-frame consume toward
/// holding the reservoir at target. Gentle, so the loop ignores the bursty sawtooth (the reservoir
/// margin absorbs that) and only corrects the slow drift — ≈ ±1 sample per pixel. "Slew, never step".
const RESERVOIR_GAIN: f64 = 0.005;
/// Reservoir target = this × the observed audio block size — the minimal slack that still absorbs the
/// bursty arrival (one block can land between two renders). Adaptive → smallest latency that works.
const RESERVOIR_BLOCKS: f64 = 2.0;
/// Decay for the tracked block size (recent max arrival), so the target shrinks back after a big
/// block and adapts to the host's buffer setting.
const BLOCK_DECAY: f64 = 0.999;
/// Floor on the reservoir target (samples-as-seconds), so it's never absurdly small at tiny blocks.
const RESERVOIR_MIN_SECONDS: f64 = 0.008;

/// Per-frame scroll diagnostics (gated on `NANO_DEBUG_SCROLL`). Confirms the smoothness claim with
/// data: over a window it reports the per-frame pixel step (min/max — equal means dead-uniform, no
/// rounding wobble) and the samples-per-col span (the zoom "breathing", which should be tiny).
#[derive(Default)]
struct ScrollDbg {
    on: bool,
    n: u32,
    last_col: i64,
    d_min: i64,
    d_max: i64,
    spp_min: f64,
    spp_max: f64,
}

impl ScrollDbg {
    fn tick(&mut self, col: i64, spp: f64, px_per_frame: i64) {
        if !self.on {
            return;
        }
        if self.n == 0 {
            self.d_min = i64::MAX;
            self.d_max = i64::MIN;
            self.spp_min = f64::MAX;
            self.spp_max = f64::MIN;
        } else {
            let d = col - self.last_col;
            self.d_min = self.d_min.min(d);
            self.d_max = self.d_max.max(d);
        }
        self.spp_min = self.spp_min.min(spp);
        self.spp_max = self.spp_max.max(spp);
        self.last_col = col;
        self.n += 1;
        if self.n >= 240 {
            eprintln!(
                "[nano-scroll] px/frame={px_per_frame} step Δ {}..{} | spp {:.3}..{:.3} (zoom span {:.4}%)",
                self.d_min,
                self.d_max,
                self.spp_min,
                self.spp_max,
                (self.spp_max - self.spp_min) / self.spp_min * 100.0
            );
            self.n = 0;
        }
    }
}

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 3],
}

/// Per-viewport-size offscreen render target: a 4× MSAA color texture the contour draws into, plus
/// the resolved single-sample texture + a bind group to sample it when compositing (ADR 0007).
struct Offscreen {
    width: u32,
    height: u32,
    msaa_view: wgpu::TextureView,
    resolved_view: wgpu::TextureView,
    composite_bind_group: wgpu::BindGroup,
}

pub struct WaveformModule {
    store: WaveStore,

    // Contour pipeline (draws into the offscreen MSAA target).
    contour_pipeline: wgpu::RenderPipeline,
    vertex_buffer: wgpu::Buffer,
    vertex_count_l: u32,
    vertex_count_r: u32,
    verts: Vec<Vertex>,

    // Composite pipeline (samples the resolved offscreen texture 1:1 into the host's shared pass).
    composite_pipeline: wgpu::RenderPipeline,
    composite_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    format: wgpu::TextureFormat,
    offscreen: Option<Offscreen>,

    // Incremental scroll: a ring of immutable built columns. Each render builds `px_per_frame` new
    // columns from the freshest audio (sizes flexing to track clock drift), pushes them on the right,
    // drops as many from the left. Old columns never re-map → no stretch; px/render → uniform motion.
    display_cols: VecDeque<store::BaseBin>, // the visible columns, oldest→newest (length = columns)
    next_sample: f64,                       // cursor: absolute sample where the next new column starts
    avg_arrival: f64,                       // EMA of samples closed per render (≈ sample_rate / fps)
    avg_seeded: bool,
    block_size: f64,  // tracked audio block size (recent max arrival) → adaptive reservoir target
    px_per_frame: i64,
    ring_init: bool,  // display ring filled (rebuilt on first run / resize / rate change)
    last_columns: usize,
    prev_closed: u64,                    // closed_samples last render (for the per-render delta)
    last_audio_advance: Option<Instant>, // when audio last advanced — drives pause detection
    last_sample_rate: f32,
    scroll_dbg: ScrollDbg,
}

impl WaveformModule {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let window_bins = (STORE_WINDOW_SECONDS / store::BIN_SECONDS).round().max(1.0) as usize;
        let store = WaveStore::new(window_bins, BAND_LOW_HZ, BAND_HIGH_HZ);

        // ── Contour pipeline: colored triangle strips, rendered MSAA into the offscreen target ──
        let contour_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("waveform-contour-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(CONTOUR_WGSL)),
        });
        let contour_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("waveform-contour-pl"),
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
        let contour_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("waveform-contour-pipeline"),
            layout: Some(&contour_pl),
            vertex: wgpu::VertexState {
                module: &contour_shader,
                entry_point: Some("vs_main"),
                buffers: &[vertex_layout],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &contour_shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: None,
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleStrip,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState {
                count: MSAA_SAMPLES,
                ..Default::default()
            },
            multiview_mask: None,
            cache: None,
        });

        let vbuf_bytes = (4 * MAX_COLUMNS * std::mem::size_of::<Vertex>()) as u64;
        let vertex_buffer = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("waveform-vbuf"),
            contents: &vec![0u8; vbuf_bytes as usize],
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        });

        // ── Composite pipeline: full-viewport triangle sampling the resolved offscreen 1:1 ──
        let composite_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("waveform-composite-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(COMPOSITE_WGSL)),
        });
        let composite_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("waveform-composite-bgl"),
            entries: &[
                wgpu::BindGroupLayoutEntry {
                    binding: 0,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Texture {
                        sample_type: wgpu::TextureSampleType::Float { filterable: true },
                        view_dimension: wgpu::TextureViewDimension::D2,
                        multisampled: false,
                    },
                    count: None,
                },
                wgpu::BindGroupLayoutEntry {
                    binding: 1,
                    visibility: wgpu::ShaderStages::FRAGMENT,
                    ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                    count: None,
                },
            ],
        });
        let composite_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("waveform-composite-pl"),
            bind_group_layouts: &[Some(&composite_layout)],
            immediate_size: 0,
        });
        let composite_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("waveform-composite-pipeline"),
            layout: Some(&composite_pl),
            vertex: wgpu::VertexState {
                module: &composite_shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &composite_shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("waveform-sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        Self {
            store,
            contour_pipeline,
            vertex_buffer,
            vertex_count_l: 0,
            vertex_count_r: 0,
            verts: Vec::with_capacity(4 * MAX_COLUMNS),
            composite_pipeline,
            composite_layout,
            sampler,
            format,
            offscreen: None,
            display_cols: VecDeque::new(),
            next_sample: 0.0,
            avg_arrival: 0.0,
            avg_seeded: false,
            block_size: 0.0,
            px_per_frame: 1,
            ring_init: false,
            last_columns: 0,
            prev_closed: 0,
            last_audio_advance: None,
            last_sample_rate: 0.0,
            scroll_dbg: ScrollDbg {
                on: std::env::var_os("NANO_DEBUG_SCROLL").is_some(),
                ..Default::default()
            },
        }
    }

    /// (Re)allocate the offscreen MSAA + resolved textures when the viewport size changes; guards
    /// against zero/sub-1px sizes during a collapsed column.
    fn ensure_offscreen(&mut self, device: &wgpu::Device, w: u32, h: u32) {
        let w = w.max(1);
        let h = h.max(1);
        if let Some(o) = &self.offscreen {
            if o.width == w && o.height == h {
                return;
            }
        }
        let make = |label, samples, usage| {
            device.create_texture(&wgpu::TextureDescriptor {
                label: Some(label),
                size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
                mip_level_count: 1,
                sample_count: samples,
                dimension: wgpu::TextureDimension::D2,
                format: self.format,
                usage,
                view_formats: &[],
            })
        };
        let msaa = make("waveform-msaa", MSAA_SAMPLES, wgpu::TextureUsages::RENDER_ATTACHMENT);
        let resolved = make(
            "waveform-resolved",
            1,
            wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
        );
        let msaa_view = msaa.create_view(&wgpu::TextureViewDescriptor::default());
        let resolved_view = resolved.create_view(&wgpu::TextureViewDescriptor::default());
        let composite_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("waveform-composite-bg"),
            layout: &self.composite_layout,
            entries: &[
                wgpu::BindGroupEntry {
                    binding: 0,
                    resource: wgpu::BindingResource::TextureView(&resolved_view),
                },
                wgpu::BindGroupEntry {
                    binding: 1,
                    resource: wgpu::BindingResource::Sampler(&self.sampler),
                },
            ],
        });
        self.offscreen = Some(Offscreen { width: w, height: h, msaa_view, resolved_view, composite_bind_group });
    }
}

impl Module for WaveformModule {
    fn update(&mut self, ctx: &FrameContext, _queue: &wgpu::Queue) {
        if ctx.sample_rate != self.last_sample_rate {
            self.last_sample_rate = ctx.sample_rate;
            // Store clears its sample clock on a rate change → re-measure the arrival rate + refill.
            self.prev_closed = 0;
            self.avg_seeded = false;
            self.ring_init = false;
        }
        self.store.set_sample_rate(ctx.sample_rate);
        if !self.store.is_active() {
            return;
        }
        for &[l, r] in ctx.new {
            self.store.push(l, r);
        }
    }

    fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
    ) {
        if !self.store.is_active() {
            self.vertex_count_l = 0;
            self.vertex_count_r = 0;
            return;
        }

        let columns = (viewport.w.round() as usize).clamp(1, MAX_COLUMNS);
        let sr = self.last_sample_rate as f64;
        let now = Instant::now();
        let closed = self.store.closed_samples();

        // Measure the audio that arrived this render. avg_arrival ≈ sample_rate / refresh; block_size
        // tracks the host's buffer (recent peak) to size the reservoir. Pause = a sustained stall.
        let dclosed = closed.saturating_sub(self.prev_closed) as f64;
        let first = self.prev_closed == 0; // first frame after (re)start: dclosed is the pre-roll backlog
        self.prev_closed = closed;
        if dclosed > 0.0 {
            self.last_audio_advance = Some(now);
        }
        let audio_live = self
            .last_audio_advance
            .map(|t| (now - t).as_secs_f64() < PAUSE_SECONDS)
            .unwrap_or(false);
        if audio_live && !first {
            // Clamp outliers (the backlog frame is skipped via `first`; this guards a post-stall
            // catch-up too) so the per-frame rate estimate stays clean.
            let d = dclosed.min(sr * 0.05);
            self.avg_arrival = if self.avg_seeded {
                self.avg_arrival * (1.0 - ARRIVAL_BETA) + d * ARRIVAL_BETA
            } else if d > 0.0 {
                self.avg_seeded = true;
                d
            } else {
                self.avg_arrival
            };
            self.block_size = (self.block_size * BLOCK_DECAY).max(d);
        }

        // Adaptive reservoir target: a couple of audio blocks behind the edge — the minimal slack that
        // absorbs bursty arrival. The nominal column width S = arrival / px.
        let reservoir_target = (RESERVOIR_BLOCKS * self.block_size).max(RESERVOIR_MIN_SECONDS * sr);
        // Need a measured rate and enough audio buffered before we can build columns.
        if !self.avg_seeded || (closed as f64) <= reservoir_target + self.avg_arrival {
            self.vertex_count_l = 0;
            self.vertex_count_r = 0;
            return;
        }
        // Pick the integer pixel step with hysteresis: only change it when the ideal (continuous) step
        // moves clearly past the current one — so a refresh hovering at a rounding boundary can't flip
        // px every frame and trigger repeated ring rebuilds.
        let fps = (sr / self.avg_arrival).max(1.0);
        let continuous = columns as f64 / (DISPLAY_WINDOW_SECONDS * fps);
        let px_changed = !self.ring_init || (continuous - self.px_per_frame as f64).abs() > 0.6;
        if px_changed {
            self.px_per_frame = choose_px_per_frame(columns, DISPLAY_WINDOW_SECONDS, fps);
        }
        let px = self.px_per_frame;
        let s_nominal = (self.avg_arrival / px as f64).max(MIN_SAMPLES_PER_COL);

        // (Re)fill the ring on first run / resize / a pixel-step change (rate switch). One-time rebuild
        // from the store at the nominal width, ending a reservoir behind the live edge.
        if !self.ring_init || columns != self.last_columns || px_changed {
            self.last_columns = columns;
            self.next_sample = closed as f64 - reservoir_target;
            self.display_cols.clear();
            for j in 0..columns {
                // column j (0 = oldest) covers the s_nominal samples ending at next_sample - (off).
                let hi = self.next_sample - (columns - 1 - j) as f64 * s_nominal;
                let lo = hi - s_nominal;
                self.display_cols.push_back(
                    self.store.merge_sample_range(lo.round() as i64, hi.round() as i64),
                );
            }
            self.ring_init = true;
        } else if audio_live {
            // Steady incremental scroll: build EXACTLY px new columns from the freshest audio. The
            // total samples they cover is the reservoir control loop's output — the smoothed arrival
            // nudged to hold the reservoir at target — so clock drift lands in these new columns'
            // sample counts (±a little), never in the movement (always px) or the old columns.
            let reservoir = closed as f64 - self.next_sample;
            let available = (closed as f64 - self.next_sample).max(0.0);
            let consume =
                consume_samples(self.avg_arrival, reservoir, reservoir_target, RESERVOIR_GAIN, available);
            let chunk = consume / px as f64;
            for _ in 0..px {
                let lo = self.next_sample.round() as i64;
                self.next_sample += chunk;
                let hi = self.next_sample.round() as i64;
                let col = self.store.merge_sample_range(lo, hi);
                self.display_cols.pop_front();
                self.display_cols.push_back(col);
            }
        }
        // (paused → ring is left frozen)

        self.scroll_dbg.tick(self.next_sample.round() as i64, s_nominal, px);
        let cols = self.display_cols.make_contiguous();

        // Columns at exact pixel centers in the `columns`-wide offscreen: x = (2c+1)/N − 1.
        let inv_cols = 1.0 / columns as f32;
        self.verts.clear();
        for ch in 0..2 {
            for (c, merged) in cols.iter().enumerate() {
                let env = merged.env[ch];
                let hue = band_color(merged.band_ms);
                let color = [
                    hue[0] + (1.0 - hue[0]) * COLOR_WHITE_MIX,
                    hue[1] + (1.0 - hue[1]) * COLOR_WHITE_MIX,
                    hue[2] + (1.0 - hue[2]) * COLOR_WHITE_MIX,
                ];
                let x = (2.0 * c as f32 + 1.0) * inv_cols - 1.0;
                let center = HALF_CENTER[ch];
                self.verts.push(Vertex { pos: [x, center + env.max * HALF_SCALE], color });
                self.verts.push(Vertex { pos: [x, center + env.min * HALF_SCALE], color });
            }
        }
        queue.write_buffer(&self.vertex_buffer, 0, bytemuck::cast_slice(&self.verts));
        self.vertex_count_l = (2 * columns) as u32;
        self.vertex_count_r = (2 * columns) as u32;

        // Offscreen MSAA pass (columns-wide), resolved to a single-sample texture (0007).
        self.ensure_offscreen(device, columns as u32, viewport.h.round() as u32);
        let off = self.offscreen.as_ref().unwrap();
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("waveform-offscreen"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &off.msaa_view,
                resolve_target: Some(&off.resolved_view),
                ops: wgpu::Operations {
                    load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT),
                    store: wgpu::StoreOp::Store,
                },
                depth_slice: None,
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(&self.contour_pipeline);
        pass.set_vertex_buffer(0, self.vertex_buffer.slice(..));
        pass.draw(0..self.vertex_count_l, 0..1);
        pass.draw(self.vertex_count_l..(self.vertex_count_l + self.vertex_count_r), 0..1);
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        let Some(off) = &self.offscreen else { return };
        if self.vertex_count_l == 0 {
            return;
        }
        // Composite the resolved (antialiased) contour 1:1 over the host's cleared background.
        rpass.set_pipeline(&self.composite_pipeline);
        rpass.set_bind_group(0, &off.composite_bind_group, &[]);
        rpass.draw(0..3, 0..1);
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
    return vec4<f32>(in.color, 1.0);
}
"#;

// Full-viewport triangle sampling the resolved offscreen contour 1:1 (no offset — the scroll is
// whole-pixel, done by shifting the rendered columns, so no sub-pixel sampling is needed).
const COMPOSITE_WGSL: &str = r#"
struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VsOut {
    var uv = vec2<f32>(f32((idx << 1u) & 2u), f32(idx & 2u));
    var o: VsOut;
    o.clip = vec4<f32>(uv * 2.0 - 1.0, 0.0, 1.0);
    o.uv = vec2<f32>(uv.x, 1.0 - uv.y); // flip Y: framebuffer origin top-left
    return o;
}

@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return textureSample(tex, samp, in.uv);
}
"#;
