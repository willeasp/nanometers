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
/// Viewable window the display targets (spec §6 — Module config later). The actual window is
/// refresh-snapped a hair off this so the scroll is an exact integer px/frame.
const DISPLAY_WINDOW_SECONDS: f64 = 5.0;
/// The base-bin store holds more than the display window so the left edge never clips. The display
/// span peaks at ~7.5s when px_per_frame rounds to 1 on a narrow window; 8s covers it.
const STORE_WINDOW_SECONDS: f32 = 8.0;
/// A frame longer than this is a gap (occlusion, stall) — its dt is ignored for the fps estimate so
/// it doesn't poison the lock and force a spurious relock.
const GAP_SECONDS: f64 = 0.1;
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
/// Re-lock the scroll clock when the measured fps drifts more than this fraction from the locked
/// value, so a stable refresh gives a stable px/frame.
const FPS_RELOCK_FRAC: f64 = 0.08;
/// Seed the refresh estimate only once two consecutive clean frames agree within this fraction, so a
/// single outlier (init lag, an occlusion-recovery frame) can't lock in a wrong fps.
const FPS_AGREE_FRAC: f64 = 0.15;
/// Slow tracking weight on each new clean frame once seeded (the estimate is already close).
const FPS_EMA_ALPHA: f64 = 0.05;

/// The display runs a small BUFFER of closed columns behind the live edge, so it can advance by a
/// fixed whole `px_per_frame` every frame (driven by the frame clock) while the buffer absorbs the
/// audio's bursty per-frame arrival. This decoupling is what makes the scroll uniform — without it
/// the display tracks the jittery closed-bin edge directly. Units are columns; at ~200 samples/col,
/// 12 cols ≈ 50 ms of display latency (imperceptible for a meter). The clock is held at TARGET by a
/// hysteretic ±1px nudge: a Schmitt trigger latches a single-pixel correction when avail leaves
/// [LOW, HIGH] and releases it only back at TARGET, so a value hovering at a band edge can't flip
/// the step every frame. A gross desync (> RESYNC, or anchor ahead of the edge) is a discontinuity
/// — a rate-change refill, first fill, long-stall recovery — and snaps rather than crawling.
const BUFFER_TARGET_COLUMNS: i64 = 12;
const BUFFER_LOW_COLUMNS: i64 = 6;
const BUFFER_HIGH_COLUMNS: i64 = 24;
const BUFFER_RESYNC_COLUMNS: i64 = 40;

/// Integer pixels the contour moves per display frame: round the ideal continuous rate
/// (`columns / (window · fps)`) to the nearest whole pixel, at least 1.
fn pixels_per_frame(columns: usize, window_seconds: f64, fps: f64) -> i64 {
    if window_seconds <= 0.0 || fps <= 0.0 {
        return 1;
    }
    ((columns as f64 / (window_seconds * fps)).round() as i64).max(1)
}

/// Samples each column spans so the audio column-rate equals the display rate (`px_per_frame · fps`)
/// — i.e. `samples_per_col · px_per_frame · fps == sample_rate`, which is what makes the uniform
/// integer scroll drift-free.
fn samples_per_column(sample_rate: f64, px_per_frame: i64, fps: f64) -> f64 {
    let denom = px_per_frame as f64 * fps;
    if denom <= 0.0 {
        return 1.0;
    }
    sample_rate / denom
}

/// One frame's update to the refresh-rate estimator. `inst` is the clamped instantaneous fps, or
/// `None` for a gap frame (occlusion/stall) which is ignored. Returns the new
/// `(fps_est, seeded, prev_clean)`. Seeds (to the mean) only when two consecutive clean frames agree
/// within `FPS_AGREE_FRAC` — so the lock is established from a representative pair, never a lone
/// outlier — then tracks slowly. Pure, so the policy is unit-testable without a frame clock.
fn fps_estimate(
    inst: Option<f64>,
    fps_est: f64,
    seeded: bool,
    prev_clean: Option<f64>,
) -> (f64, bool, Option<f64>) {
    let Some(inst) = inst else {
        return (fps_est, seeded, prev_clean); // gap frame: leave everything as-is
    };
    if seeded {
        return (fps_est * (1.0 - FPS_EMA_ALPHA) + inst * FPS_EMA_ALPHA, true, prev_clean);
    }
    match prev_clean {
        Some(prev) if (inst - prev).abs() / prev <= FPS_AGREE_FRAC => {
            (0.5 * (inst + prev), true, prev_clean) // two agree → seed
        }
        _ => (fps_est, false, Some(inst)), // first clean frame, or a disagreement → retry next pair
    }
}

/// Advance the buffered scroll anchor one frame. Pure controller (no GPU), so the smoothness logic
/// is unit-testable. Given the current anchor, the newest fully-closed column `last_full`, the
/// per-frame pixel step, and the hysteresis latch `correcting` (−1/0/+1), returns the new
/// `(scroll_col, correcting)`. Invariant on return: `scroll_col <= last_full` (never renders an
/// unclosed/partial column). See `BUFFER_TARGET_COLUMNS` for the band semantics.
fn advance_scroll(scroll_col: i64, last_full: i64, px_per_frame: i64, correcting: i8) -> (i64, i8) {
    let avail = last_full - scroll_col;
    // Gross desync (discontinuity) → snap behind the edge instead of crawling back over many frames.
    if avail < 0 || avail > BUFFER_RESYNC_COLUMNS {
        return (last_full - BUFFER_TARGET_COLUMNS, 0);
    }
    // Schmitt trigger: latch a ±1 correction at a band edge, release only back at TARGET.
    let mut c = correcting;
    if c == 0 {
        if avail > BUFFER_HIGH_COLUMNS {
            c = 1;
        } else if avail < BUFFER_LOW_COLUMNS {
            c = -1;
        }
    } else if (c > 0 && avail <= BUFFER_TARGET_COLUMNS) || (c < 0 && avail >= BUFFER_TARGET_COLUMNS) {
        c = 0;
    }
    let mut step = px_per_frame + c as i64;
    if step > avail {
        step = avail.max(0); // never cross the live edge (pause/severe stall → freeze on it)
    }
    (scroll_col + step.max(0), c)
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

    // Scroll clock (the subway-sign uniform integer-pixel scroll).
    fps_est: f64,
    fps_seeded: bool,
    prev_clean_fps: Option<f64>, // last clean inst-fps awaiting a second agreeing frame to seed
    locked_fps: f64,
    px_per_frame: i64,
    samples_per_col: f64,
    scroll_col: i64, // display anchor in whole columns (= pixels), buffered behind the live edge
    correcting: i8,  // hysteresis latch for the ±1px buffer-depth nudge (−1/0/+1)
    scroll_init: bool,
    last_columns: usize,
    last_sample_rate: f32,
    last_frame: Option<Instant>,
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
            prev_clean_fps: None,
            locked_fps: 0.0,
            px_per_frame: 1,
            samples_per_col: 1.0,
            scroll_col: 0,
            correcting: 0,
            scroll_init: false,
            last_columns: 0,
            last_sample_rate: 0.0,
            last_frame: None,
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
            self.scroll_init = false; // store clears its clocks on a rate change → re-anchor
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

        // Measure the refresh rate to size the uniform pixel step. A gap frame (occlusion/stall,
        // dt > GAP_SECONDS) is passed as None so its huge dt can't poison the estimate; seeding then
        // waits for two clean frames to agree (no lock to a startup outlier — see `fps_estimate`).
        let now = Instant::now();
        let dt = self.last_frame.map(|t| (now - t).as_secs_f64());
        self.last_frame = Some(now);
        let inst = dt
            .filter(|&d| d < GAP_SECONDS)
            .map(|d| (1.0 / d.max(1e-4)).clamp(20.0, 360.0));
        let (fps, seeded, prev) = fps_estimate(inst, self.fps_est, self.fps_seeded, self.prev_clean_fps);
        self.fps_est = fps;
        self.fps_seeded = seeded;
        self.prev_clean_fps = prev;
        if !self.fps_seeded {
            // No trustworthy refresh measurement yet — don't lock the scroll clock to a guess. One
            // or two blank frames at startup are invisible.
            self.vertex_count_l = 0;
            self.vertex_count_r = 0;
            return;
        }

        let columns = (viewport.w.round() as usize).clamp(1, MAX_COLUMNS);
        let sr = self.last_sample_rate as f64;

        // (Re)lock the pixel step + column width on a real scale change (uninitialized, viewport
        // resize, rate change, or a settled refresh that drifted past FPS_RELOCK_FRAC). Rare now, so
        // re-anchoring the buffer here is fine.
        let fps_drifted = self.locked_fps > 0.0
            && (self.fps_est - self.locked_fps).abs() / self.locked_fps > FPS_RELOCK_FRAC;
        let relock = !self.scroll_init || columns != self.last_columns || fps_drifted;
        if relock {
            self.last_columns = columns;
            self.locked_fps = self.fps_est;
            self.px_per_frame = pixels_per_frame(columns, DISPLAY_WINDOW_SECONDS, self.fps_est);
            self.samples_per_col = samples_per_column(sr, self.px_per_frame, self.fps_est);
        }
        // The newest fully-closed column (rightmost columns must be fully populated).
        let last_full = (self.store.closed_samples() as f64 / self.samples_per_col).floor() as i64 - 1;
        if relock {
            // Re-anchor the buffer behind the live edge; the subway clock takes over next frame.
            self.scroll_col = last_full - BUFFER_TARGET_COLUMNS;
            self.correcting = 0;
            self.scroll_init = true;
        } else {
            // Subway scroll: advance by EXACTLY px_per_frame off the frame clock, with a hysteretic
            // ±1px nudge that keeps the display buffered behind the live edge (see `advance_scroll`).
            let (sc, c) = advance_scroll(self.scroll_col, last_full, self.px_per_frame, self.correcting);
            self.scroll_col = sc;
            self.correcting = c;
        }
        let rightmost_col = self.scroll_col;
        debug_assert!(rightmost_col <= last_full, "scroll anchor must stay behind the live edge");
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
    fn pixels_per_frame_rounds_to_whole_pixels() {
        // 1224 px over 5 s at 120 Hz → 1224/600 = 2.04 → 2 px/frame.
        assert_eq!(pixels_per_frame(1224, 5.0, 120.0), 2);
        // Same window at 60 Hz → 1224/300 = 4.08 → 4 px/frame (twice as many, half the rate).
        assert_eq!(pixels_per_frame(1224, 5.0, 60.0), 4);
        // Never zero.
        assert_eq!(pixels_per_frame(100, 100.0, 60.0), 1);
    }

    #[test]
    fn samples_per_column_makes_rates_match() {
        // The drift-free invariant: samples_per_col · (px_per_frame · fps) == sample_rate, so the
        // audio produces columns at exactly the rate the display consumes them.
        let sr = 48000.0;
        let ppf = pixels_per_frame(1224, 5.0, 120.0); // 2
        let spc = samples_per_column(sr, ppf, 120.0);
        assert!((spc - 200.0).abs() < 1e-9, "48000/(2·120) = 200 samples/col");
        assert!((spc * ppf as f64 * 120.0 - sr).abs() < 1e-6, "rates match → no drift");
    }

    // ── fps_estimate: seed only when two clean frames agree; then track slowly ──

    #[test]
    fn fps_gap_frame_leaves_estimate_unchanged() {
        // A gap (occlusion/stall) is passed as None and must not move the estimate or the latch.
        assert_eq!(fps_estimate(None, 60.0, false, Some(58.0)), (60.0, false, Some(58.0)));
        assert_eq!(fps_estimate(None, 120.0, true, None), (120.0, true, None));
    }

    #[test]
    fn fps_first_clean_frame_records_but_does_not_seed() {
        // One clean frame is not enough — record it, leave fps_est untouched until a second agrees.
        assert_eq!(fps_estimate(Some(120.0), 60.0, false, None), (60.0, false, Some(120.0)));
    }

    #[test]
    fn fps_two_agreeing_frames_seed_to_their_mean() {
        // Two consecutive clean frames within AGREE_FRAC → seed (mean), so a lone outlier can't.
        let (fps, seeded, _) = fps_estimate(Some(120.0), 60.0, false, Some(118.0));
        assert!((fps - 119.0).abs() < 1e-9);
        assert!(seeded);
    }

    #[test]
    fn fps_disagreeing_frame_is_rejected_as_outlier() {
        // A 60→120 jump (e.g. an occlusion-recovery frame): don't seed, retry against the latest.
        assert_eq!(fps_estimate(Some(120.0), 60.0, false, Some(60.0)), (60.0, false, Some(120.0)));
    }

    #[test]
    fn fps_seeded_frame_tracks_with_slow_ema() {
        let (fps, seeded, _) = fps_estimate(Some(119.0), 120.0, true, None);
        assert!((fps - 119.95).abs() < 1e-9, "120·0.95 + 119·0.05");
        assert!(seeded);
    }

    // ── advance_scroll: uniform px/frame with a hysteretic ±1 nudge toward the buffer target ──

    #[test]
    fn scroll_advances_by_exact_px_per_frame_when_buffered() {
        // avail == TARGET (12), inside the band → no correction, exactly px_per_frame.
        assert_eq!(advance_scroll(100, 112, 2, 0), (102, 0));
    }

    #[test]
    fn scroll_catches_up_one_pixel_when_latency_runs_high() {
        // avail (30) > HIGH (24) → latch +1, step px_per_frame + 1.
        assert_eq!(advance_scroll(0, 30, 2, 0), (3, 1));
    }

    #[test]
    fn scroll_correction_latches_through_the_band_then_releases_at_target() {
        // Latched +1 persists while avail is between TARGET and HIGH (no per-frame flap)…
        assert_eq!(advance_scroll(0, 20, 2, 1), (3, 1));
        // …and releases (back to plain px_per_frame) once avail returns to TARGET.
        assert_eq!(advance_scroll(0, 12, 2, 1), (2, 0));
    }

    #[test]
    fn scroll_eases_off_one_pixel_when_buffer_runs_low() {
        // avail (4) < LOW (6) → latch −1 so the buffer refills.
        assert_eq!(advance_scroll(0, 4, 2, 0), (1, -1));
    }

    #[test]
    fn scroll_snaps_on_gross_desync_instead_of_crawling() {
        // avail (200) ≫ RESYNC (40): a discontinuity (rate-change refill) → snap behind the edge,
        // don't crawl hundreds of +1 frames. Latch clears.
        assert_eq!(advance_scroll(0, 200, 2, 1), (188, 0));
        // Anchor somehow ahead of the live edge (avail < 0) also snaps.
        assert_eq!(advance_scroll(100, 50, 2, 0), (38, 0));
    }

    #[test]
    fn scroll_never_crosses_the_live_edge_on_stall() {
        // Buffer drained to the edge (avail 0, e.g. paused): step clamps to 0, anchor frozen at edge.
        assert_eq!(advance_scroll(11, 11, 2, 0), (11, -1));
        // avail 1 with px_per_frame 2: would overshoot, clamps to land exactly on the edge.
        assert_eq!(advance_scroll(10, 11, 2, 0), (11, -1));
    }
}
