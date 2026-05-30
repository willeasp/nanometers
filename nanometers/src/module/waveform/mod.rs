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

pub mod color;
pub mod store;

use bytemuck::{Pod, Zeroable};
use std::borrow::Cow;
use std::time::Instant;
use wgpu::util::DeviceExt;

use super::{EventStatus, FrameContext, Module, Rect};
use color::band_color;
use store::WaveStore;

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

/// The newest drawn column is held this far (in samples) behind the live audio edge. The integer
/// pixel step never depends on the bursty audio arrival; this slack is what lets it run uniformly
/// without the edge ever overtaking it. ~50 ms — imperceptible, comfortably > per-frame arrival jitter.
const BUFFER_SECONDS: f64 = 0.05;
/// No new closed audio for longer than this → paused; freeze the scroll. Loose enough that ordinary
/// bursty arrival isn't mistaken for a pause.
const PAUSE_SECONDS: f64 = 0.1;
/// Floor on samples-per-column (a column must hold at least one base bin's worth).
const MIN_SAMPLES_PER_COL: f64 = 1.0;
/// Samples-per-column is only trimmed when it's more than this fraction off the buffer-holding
/// target — so steady state is a FROZEN zoom plus a pure integer scroll (no per-frame motion in the
/// float at all), and the trim only cancels slow drift. Wider than per-frame arrival jitter.
const SPP_DEADBAND_FRAC: f64 = 0.02;
/// When it does trim, low-pass the zoom toward the target by this much per frame (slow → the rare
/// correction is a sub-pixel zoom nudge spread over many frames, never a visible jump).
const SPP_TRIM_ALPHA: f64 = 0.02;
/// Tracking weight for the rough refresh estimate (used only to pick the integer pixel step).
const FPS_EMA_ALPHA: f64 = 0.1;
/// Only change the integer pixel step once the ideal (continuous) step is this far past the current
/// one — hysteresis so a refresh hovering at a rounding boundary can't flap the step.
const PX_HYSTERESIS: f64 = 0.35;

/// Integer pixels the contour moves per render: round the ideal continuous rate
/// (`columns / (window · fps)`) to a whole pixel, at least 1. The rounding is robust — a fps estimate
/// off by several percent still picks the same integer — and `samples_per_col` absorbs the residual.
fn choose_px_per_frame(columns: usize, window_seconds: f64, fps: f64) -> i64 {
    if window_seconds <= 0.0 || fps <= 0.0 {
        return 1;
    }
    ((columns as f64 / (window_seconds * fps)).round() as i64).max(1)
}

/// One frame of the scroll. Pure controller (no GPU), so it's unit-testable. The column anchor
/// advances by EXACTLY `px_per_frame` whole pixels — integer arithmetic, no rounding, the one thing
/// that moves the picture, so motion is dead-uniform. The display/audio clock mismatch is absorbed
/// by trimming `spp` (samples-per-column = zoom) toward the value that holds the newest column
/// `buffer_samples` behind the live edge — but only outside a deadband, so steady state is a frozen
/// zoom + pure integer scroll. Returns the new `(scroll_col, spp)`; the drawn column is `scroll_col`.
fn advance_scroll(
    scroll_col: i64,
    spp: f64,
    px_per_frame: i64,
    closed: u64,
    buffer_samples: f64,
    alpha: f64,
    audio_live: bool,
) -> (i64, f64) {
    if !audio_live {
        return (scroll_col, spp); // paused → freeze both anchor and zoom
    }
    let col = scroll_col + px_per_frame; // pure integer step — no float, no rounding
    let target = (closed as f64 - buffer_samples) / (col as f64 + 1.0);
    let spp = if (target - spp).abs() > spp * SPP_DEADBAND_FRAC {
        spp + alpha * (target - spp) // outside the deadband → trim the zoom toward target
    } else {
        spp // inside the deadband → frozen; nothing but the integer anchor moves
    };
    let spp = spp.max(MIN_SAMPLES_PER_COL);
    // Never draw past the newest fully-closed column (startup/underrun) → clamp the anchor back.
    let max_col = (closed as f64 / spp).floor() as i64 - 1;
    (col.min(max_col), spp)
}

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

    // Scroll clock: fixed integer pixels/render, samples-per-col trims to hold the buffer (see
    // `advance_scroll`). The pixel motion is pure integer — no float, no rounding.
    fps_est: f64,    // rough refresh estimate, only to pick the integer pixel step
    fps_seeded: bool,
    px_per_frame: i64,
    samples_per_col: f64, // zoom = samples per column; the slowly-trimmed control variable
    scroll_col: i64,      // integer column anchor (= rightmost pixel), advanced by px_per_frame
    scroll_init: bool,
    last_closed: u64,                    // closed_samples last frame, to detect audio progress
    last_audio_advance: Option<Instant>, // when audio last advanced — drives pause detection
    last_sample_rate: f32,
    last_frame: Option<Instant>,
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
            fps_est: 60.0,
            fps_seeded: false,
            px_per_frame: 1,
            samples_per_col: 1.0,
            scroll_col: 0,
            scroll_init: false,
            last_closed: 0,
            last_audio_advance: None,
            last_sample_rate: 0.0,
            last_frame: None,
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
            // Store clears its sample clock on a rate change → re-anchor the scroll from scratch.
            self.last_closed = 0;
            self.scroll_init = false;
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
        let dt = self.last_frame.map(|t| (now - t).as_secs_f64());
        self.last_frame = Some(now);

        // Rough refresh estimate — used ONLY to pick the integer pixel step. A few % error is fine
        // (it's just rounding); the samples-per-col control loop absorbs the residual. Gap frames
        // (occlusion/stall) are skipped so they can't drag it.
        if let Some(dt) = dt {
            if dt > 0.0 && dt < PAUSE_SECONDS {
                let inst = (1.0 / dt).clamp(20.0, 360.0);
                self.fps_est = if self.fps_seeded {
                    self.fps_est * (1.0 - FPS_EMA_ALPHA) + inst * FPS_EMA_ALPHA
                } else {
                    self.fps_seeded = true;
                    inst
                };
            }
        }
        // Pick the fixed pixel step, with hysteresis so a refresh at a rounding boundary can't flap it.
        let continuous = columns as f64 / (DISPLAY_WINDOW_SECONDS * self.fps_est.max(1.0));
        if !self.scroll_init || (continuous - self.px_per_frame as f64).abs() > PX_HYSTERESIS {
            self.px_per_frame = choose_px_per_frame(columns, DISPLAY_WINDOW_SECONDS, self.fps_est);
        }

        // Pause detection: bursty per-frame arrival is fine; only a sustained stall freezes the scroll.
        let closed = self.store.closed_samples();
        if closed > self.last_closed {
            self.last_closed = closed;
            self.last_audio_advance = Some(now);
        }
        let audio_live = self
            .last_audio_advance
            .map(|t| (now - t).as_secs_f64() < PAUSE_SECONDS)
            .unwrap_or(false);

        let buffer_samples = BUFFER_SECONDS * sr;
        // Anchor the integer column + zoom once, behind the live edge, when audio and a refresh
        // estimate are both available. A few blank startup frames are invisible.
        if !self.scroll_init {
            if !self.fps_seeded || (closed as f64) <= buffer_samples {
                self.vertex_count_l = 0;
                self.vertex_count_r = 0;
                return;
            }
            self.samples_per_col = (sr / (self.px_per_frame as f64 * self.fps_est)).max(MIN_SAMPLES_PER_COL);
            self.scroll_col = ((closed as f64 - buffer_samples) / self.samples_per_col).floor().max(0.0) as i64;
            self.scroll_init = true;
        }

        // Advance: exactly px_per_frame whole pixels (the only thing that moves the picture); the
        // zoom trims sub-pixel, deadbanded, to hold the buffer against clock drift (see `advance_scroll`).
        let (col, spp) = advance_scroll(
            self.scroll_col,
            self.samples_per_col,
            self.px_per_frame,
            closed,
            buffer_samples,
            SPP_TRIM_ALPHA,
            audio_live,
        );
        self.scroll_col = col;
        self.samples_per_col = spp;
        self.scroll_dbg.tick(col, spp, self.px_per_frame);
        let rightmost_col = self.scroll_col;
        let cols = self.store.build_columns(columns, self.samples_per_col, rightmost_col);

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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn px_per_frame_rounds_to_a_whole_step() {
        // 1200 px over 5 s at 120 Hz → 1200/600 = 2.0 → 2 px/frame.
        assert_eq!(choose_px_per_frame(1200, 5.0, 120.0), 2);
        // Same window at 60 Hz → 1200/300 = 4.0 → 4 px/frame (half the rate, twice as many).
        assert_eq!(choose_px_per_frame(1200, 5.0, 60.0), 4);
        // Never zero, even on a tiny/odd window.
        assert_eq!(choose_px_per_frame(50, 5.0, 120.0), 1);
    }

    // ── advance_scroll: fixed integer pixels/frame, samples-per-col trims to hold the buffer ──
    // Steady-state reference: 1200 px / 5 s @ 120 Hz, sr 48 kHz → px_per_frame 2, spp 200, the
    // newest drawn column sits buffer = 0.05·48000 = 2400 samples behind the live edge.

    #[test]
    fn scroll_steps_a_fixed_whole_pixel_amount() {
        // At the control loop's fixed point (target == spp), the anchor advances by exactly
        // px_per_frame and spp doesn't move — dead-uniform motion, no zoom breathing.
        // closed chosen so (closed − buffer)/(col+1) == spp: col=602, spp=200 → closed = 200·603+2400.
        let closed = (200.0 * 603.0 + 2400.0) as u64;
        let (col, spp) = advance_scroll(600, 200.0, 2, closed, 2400.0, 0.02, true);
        assert_eq!(col, 602, "anchor advanced by exactly px_per_frame");
        assert!((spp - 200.0).abs() < 1e-6, "spp steady at the fixed point, got {spp}");
    }

    #[test]
    fn scroll_absorbs_clock_mismatch_into_spp_not_the_step() {
        // Audio edge ahead of the steady point: the STEP stays px_per_frame (uniform), while spp
        // trims toward the higher target — the mismatch goes into the (invisible) zoom, not the pixel.
        let (col, spp) = advance_scroll(600, 200.0, 2, 130_000, 2400.0, 0.02, true);
        assert_eq!(col, 602, "pixel step is unchanged by the mismatch");
        let target = (130_000.0 - 2400.0) / 603.0; // ≈ 211.6
        let expected = 200.0 + 0.02 * (target - 200.0);
        assert!((spp - expected).abs() < 1e-6, "spp low-passes toward target, got {spp}");
        assert!(spp > 200.0 && spp < 201.0, "trim is a tiny fraction of a sample, got {spp}");
    }

    #[test]
    fn scroll_freezes_when_audio_is_not_live() {
        // Paused (audio edge stale): neither the anchor nor the zoom moves.
        assert_eq!(advance_scroll(600, 200.0, 2, 130_000, 2400.0, 0.02, false), (600, 200.0));
    }

    #[test]
    fn scroll_never_draws_past_the_closed_edge() {
        // If the anchor would land past the newest closed column (startup/underrun), clamp it back so
        // the newest drawn column is always fully closed: (col+1)·spp ≤ closed (with the trimmed spp).
        let (col, spp) = advance_scroll(600, 200.0, 2, 100_000, 2400.0, 0.02, true);
        assert!(col < 600 + 2, "anchor was clamped back from the would-be step");
        assert!(
            (col as f64 + 1.0) * spp <= 100_000.0,
            "newest column must be fully closed: ({col}+1)·{spp} > 100000"
        );
    }

    #[test]
    fn scroll_clamps_spp_to_a_sane_floor() {
        // A pathological target can't drive samples-per-col below the floor (columns must hold ≥1 bin).
        let (_, spp) = advance_scroll(600, super::MIN_SAMPLES_PER_COL, 2, 0, 2400.0, 1.0, true);
        assert!(spp >= super::MIN_SAMPLES_PER_COL);
    }
}
