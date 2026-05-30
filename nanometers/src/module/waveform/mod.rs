//! Waveform Module (ADRs 0001 / 0007 + `docs/specs/waveform-module.md`).
//!
//! A scrolling amplitude-envelope view: per channel, a filled min/max contour, spectrally colored,
//! newest sample at the right edge. Replaces the fake glow on the Oscilloscope (0007).
//!
//! Split of concerns: [`store::WaveStore`] owns the GPU-free state (base-bin ring, accumulator,
//! filterbank) and the column building (unit-tested, incl. scroll stability); this module is the
//! thin GPU wrapper. `update` folds `ctx.new` into the store; `prepare` builds the per-column
//! contour geometry for the viewport width into an offscreen MSAA target and resolves it; `render`
//! composites that resolved texture into the column. Geometry is plain [-1, 1] clip space — the
//! host sets viewport+scissor.

pub mod color;
pub mod store;

use bytemuck::{Pod, Zeroable};
use std::borrow::Cow;
use wgpu::util::DeviceExt;

use super::{EventStatus, FrameContext, Module, Rect};
use color::band_color;
use store::WaveStore;

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
const COLOR_WHITE_MIX: f32 = 0.18;
/// MSAA sample count for the Waveform's own offscreen target (0007 — host pass stays single-sample).
const MSAA_SAMPLES: u32 = 4;
/// Each display column is this many physical px wide. ≥2 px band-limits the contour so a sharp 1px
/// feature can't pulse in brightness as the sub-pixel scroll offset sweeps (a 1px feature at a
/// half-pixel offset splits its energy across two pixels → dimmer; a 2px feature keeps a
/// full-brightness leading pixel at any offset). The columns-wide offscreen is linearly upscaled
/// to the viewport at composite.
const PIXELS_PER_COLUMN: f32 = 2.0;
/// Scroll-smoothing time constant (seconds). The per-frame EMA coefficient is derived from this and
/// the measured frame dt, so the smoothing (which low-passes the ±20% per-frame sample-drain
/// jitter into a constant visual velocity) is frame-rate-independent — same feel at 60 and 120 Hz.
const SCROLL_TAU: f64 = 0.04;

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 3],
}

/// Composite uniform: sub-pixel horizontal sampling offset (in UV) that slides the resolved
/// contour smoothly between whole-column steps. `x_offset` is added to the sampled UV.x.
#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct CompositeUniform {
    x_offset: f32,
    _pad: [f32; 3],
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

    // Composite pipeline (samples the resolved offscreen texture into the host's shared pass).
    composite_pipeline: wgpu::RenderPipeline,
    composite_layout: wgpu::BindGroupLayout,
    composite_uniform: wgpu::Buffer,
    sampler: wgpu::Sampler,
    format: wgpu::TextureFormat,
    offscreen: Option<Offscreen>,

    /// Smoothed scroll position in display-column units (low-passed target); its fraction is the
    /// sub-pixel composite offset. `scroll_init` snaps it to the true position when uninitialized
    /// or after a scale change (column count or sample rate), so there's no sweep across the
    /// discontinuity. `last_*` detect those scale changes; `last_frame` clocks the dt-scaled EMA.
    display_pos: f64,
    scroll_init: bool,
    last_columns: usize,
    last_sample_rate: f32,
    last_frame: Option<std::time::Instant>,
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
        let window_bins = (window_seconds / store::BIN_SECONDS).round().max(1.0) as usize;
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

        // ── Composite pipeline: full-viewport quad sampling the resolved offscreen texture ──
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
                wgpu::BindGroupLayoutEntry {
                    binding: 2,
                    visibility: wgpu::ShaderStages::VERTEX,
                    ty: wgpu::BindingType::Buffer {
                        ty: wgpu::BufferBindingType::Uniform,
                        has_dynamic_offset: false,
                        min_binding_size: None,
                    },
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
                    // Premultiplied-ish alpha so the transparent offscreen background lets the
                    // host clear-color show through and only the contour composites.
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
        let composite_uniform = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("waveform-composite-uniform"),
            contents: bytemuck::bytes_of(&CompositeUniform { x_offset: 0.0, _pad: [0.0; 3] }),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
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
            composite_uniform,
            sampler,
            format,
            offscreen: None,
            display_pos: 0.0,
            scroll_init: false,
            last_columns: 0,
            last_sample_rate: 0.0,
            last_frame: None,
        }
    }

    /// (Re)allocate the offscreen MSAA + resolved textures when the viewport size changes (the
    /// reviewer's caching note). Guards against zero/sub-1px sizes during a collapsed column.
    fn ensure_offscreen(&mut self, device: &wgpu::Device, w: u32, h: u32) {
        let w = w.max(1);
        let h = h.max(1);
        if let Some(o) = &self.offscreen {
            if o.width == w && o.height == h {
                return;
            }
        }
        let msaa = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("waveform-msaa"),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: MSAA_SAMPLES,
            dimension: wgpu::TextureDimension::D2,
            format: self.format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT,
            view_formats: &[],
        });
        let resolved = device.create_texture(&wgpu::TextureDescriptor {
            label: Some("waveform-resolved"),
            size: wgpu::Extent3d { width: w, height: h, depth_or_array_layers: 1 },
            mip_level_count: 1,
            sample_count: 1,
            dimension: wgpu::TextureDimension::D2,
            format: self.format,
            usage: wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING,
            view_formats: &[],
        });
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
                wgpu::BindGroupEntry {
                    binding: 2,
                    resource: self.composite_uniform.as_entire_binding(),
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
            self.scroll_init = false; // store clears its clocks on a rate change → re-anchor scroll
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

        // Band-limit: ~2 px per column so the contour has no 1px features to pulse under sub-pixel
        // scroll. The columns-wide offscreen is upscaled to the viewport at composite.
        let columns =
            ((viewport.w / PIXELS_PER_COLUMN).round() as usize).clamp(1, MAX_COLUMNS);
        if columns != self.last_columns {
            self.last_columns = columns;
            self.scroll_init = false; // column scale (and thus the position unit) changed → re-anchor
        }
        let bpc = (self.store.window_bins() / columns).max(1);

        // Smooth the scroll position toward the true (sample-derived) position with a dt-scaled EMA
        // so it's frame-rate-independent. The integer part anchors which columns we render; the
        // fraction is the sub-pixel composite offset. Snapping when uninitialized/after a scale
        // change avoids a sweep across the discontinuity.
        let now = std::time::Instant::now();
        let dt = self
            .last_frame
            .map(|t| (now - t).as_secs_f64())
            .unwrap_or(1.0 / 60.0);
        self.last_frame = Some(now);
        let target = self.store.scroll_position_cols(columns);
        if self.scroll_init {
            let alpha = 1.0 - (-dt / SCROLL_TAU).exp();
            self.display_pos += (target - self.display_pos) * alpha;
        } else {
            self.display_pos = target;
            self.scroll_init = true;
        }
        // Clamp the rightmost drawn column to the last fully-closed one so the live edge never shows
        // a partial/empty column (esp. on the snap frame). frac stays the sub-pixel of display_pos.
        let rightmost_col = (self.display_pos.floor() as i64).min(self.store.last_full_column(bpc));
        let frac = (self.display_pos - self.display_pos.floor()) as f32; // [0, 1) columns

        let cols = self.store.build_columns(columns, bpc, rightmost_col);
        // Place column c at the CENTER of pixel c in the `columns`-wide offscreen: x = (2c+1)/N − 1,
        // keeping columns exactly on the pixel grid. The sub-pixel scroll comes from the composite
        // offset below, not from moving these vertices (which would re-introduce shimmer).
        let inv_cols = 1.0 / columns as f32;

        // One triangle strip per channel: L top half (center +0.5), R bottom half (−0.5) — spec §4.
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

        // Sub-pixel scroll: shift the composite sample left by `frac` of one column (= one pixel).
        // Linear filtering interpolates → smooth motion between whole-column steps.
        queue.write_buffer(
            &self.composite_uniform,
            0,
            bytemuck::bytes_of(&CompositeUniform { x_offset: frac * inv_cols, _pad: [0.0; 3] }),
        );

        // Offscreen MSAA pass: draw both contour strips, resolved to a single-sample texture (0007).
        // The offscreen is `columns` wide (1 texel/column); the composite upscales it to the
        // viewport, so a column becomes PIXELS_PER_COLUMN px and there are no 1px features to pulse.
        self.ensure_offscreen(device, columns as u32, viewport.h.round() as u32);
        let off = self.offscreen.as_ref().unwrap();
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("waveform-offscreen"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &off.msaa_view,
                resolve_target: Some(&off.resolved_view),
                ops: wgpu::Operations {
                    // Transparent clear so only the contour composites over the host background.
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
        // Composite the resolved (antialiased) contour over the host's cleared background. A
        // full-viewport quad is generated in the vertex shader from the vertex index.
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

// Full-screen triangle that samples the resolved offscreen contour. Three verts cover the viewport.
// The sub-pixel scroll offset shifts the sampled UV.x left (clamp sampler smears <1px at the edges).
const COMPOSITE_WGSL: &str = r#"
struct Uniforms { x_offset: f32 };
@group(0) @binding(2) var<uniform> u: Uniforms;

struct VsOut {
    @builtin(position) clip: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VsOut {
    // (0,0),(2,0),(0,2) in UV → a triangle covering the [0,1] viewport.
    var uv = vec2<f32>(f32((idx << 1u) & 2u), f32(idx & 2u));
    var o: VsOut;
    o.clip = vec4<f32>(uv * 2.0 - 1.0, 0.0, 1.0);
    // Shift sampling right by x_offset (content appears to scroll left), and flip Y for the
    // framebuffer's top-left origin.
    o.uv = vec2<f32>(uv.x + u.x_offset, 1.0 - uv.y);
    return o;
}

@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    return textureSample(tex, samp, in.uv);
}
"#;
