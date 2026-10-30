//! Spectrum Analyzer Module — a high-quality, exact, multi-resolution FFT spectrum (CONTEXT.md). The
//! DSP (three stitched FFTs, tone-exact at every frequency) lives in `nano_dsp::spectrum`; this module
//! runs the live + peak-hold ballistics and draws a smooth gradient-filled log-frequency / dB curve
//! with a peak overlay and a labeled grid.
//!
//! For FabFilter-grade smoothness the curve is Catmull-Rom interpolated and the whole thing renders
//! into the module's OWN 4× MSAA offscreen (ADR 0007 — the host pass stays single-sample), resolved
//! and composited 1:1 into the column; the grid labels (already glyph-AA) draw over the top.
//! Response (release/attack) and the dB floor are persisted config — the on-screen knobs tune them.

use std::borrow::Cow;

use bytemuck::{Pod, Zeroable};
use nano_dsp::spectrum::{MultiResSpectrum, SpectrumDisplay};
use wgpu_text::glyph_brush::ab_glyph::FontRef;
use wgpu_text::glyph_brush::{HorizontalAlign, Layout, Section, Text, VerticalAlign};
use wgpu_text::{BrushBuilder, TextBrush};

use super::{EventStatus, FrameContext, Module, Rect, FONT};

type Brush = TextBrush<FontRef<'static>>;

const F_LO: f32 = 20.0;
const F_HI: f32 = 20_000.0;
const DB_CEIL: f32 = 6.0;
const MSAA_SAMPLES: u32 = 4;
/// Catmull-Rom subdivisions per data point — turns the ~24-pts/octave data into a smooth curve.
const SUBDIV: usize = 6;

const FILL_TOP: [f32; 4] = [0.36, 0.66, 1.0, 0.55]; // bright at the curve…
const FILL_BOT: [f32; 4] = [0.20, 0.45, 0.85, 0.0]; // …fading to transparent at the floor
const PEAK_RGBA: [f32; 4] = [0.95, 0.86, 0.60, 0.7];
const GRID_RGBA: [f32; 4] = [0.28, 0.32, 0.40, 0.5];
const LABEL_RGBA: [f32; 4] = [0.55, 0.60, 0.70, 1.0];

const FREQ_TICKS: [(f32, &str); 8] = [
    (50.0, "50"), (100.0, "100"), (200.0, "200"), (500.0, "500"),
    (1000.0, "1k"), (2000.0, "2k"), (5000.0, "5k"), (10000.0, "10k"),
];

#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct SpectrumConfig {
    pub release_ms: f32,
    pub attack_ms: f32,
    pub db_floor: f32,
}
impl Default for SpectrumConfig {
    fn default() -> Self {
        Self { release_ms: 250.0, attack_ms: 12.0, db_floor: -100.0 }
    }
}
impl SpectrumConfig {
    fn to_bytes(self) -> Vec<u8> {
        serde_json::to_vec(&self).unwrap_or_default()
    }
    fn from_bytes(b: &[u8]) -> Self {
        serde_json::from_slice(b).unwrap_or_default()
    }
}

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 4],
}
fn v(pos: [f32; 2], color: [f32; 4]) -> Vertex {
    Vertex { pos, color }
}

/// Per-viewport-size offscreen: a 4× MSAA color texture, the resolved single-sample texture, and a
/// bind group to sample it when compositing (ADR 0007).
struct Offscreen {
    width: u32,
    height: u32,
    msaa_view: wgpu::TextureView,
    resolved_view: wgpu::TextureView,
    composite_bind_group: wgpu::BindGroup,
}

pub struct SpectrumModule {
    geom_pipeline: wgpu::RenderPipeline, // draws into the MSAA offscreen
    composite_pipeline: wgpu::RenderPipeline,
    composite_layout: wgpu::BindGroupLayout,
    sampler: wgpu::Sampler,
    format: wgpu::TextureFormat,
    offscreen: Option<Offscreen>,

    vbuf: wgpu::Buffer,
    vbuf_cap: usize,
    verts: Vec<Vertex>,
    brush: Brush,
    brush_size: (u32, u32),

    spectrum: Option<MultiResSpectrum>,
    display: SpectrumDisplay,
    sample_rate: f32,
    config: SpectrumConfig,
}

fn x_of_freq(f: f32) -> f32 {
    (f.max(F_LO).log2() - F_LO.log2()) / (F_HI.log2() - F_LO.log2()) * 2.0 - 1.0
}
fn y_of_db(db: f32, floor: f32) -> f32 {
    (-1.0 + 2.0 * (db - floor) / (DB_CEIL - floor)).clamp(-1.0, 1.0)
}
fn catmull(p0: f32, p1: f32, p2: f32, p3: f32, t: f32) -> f32 {
    let (t2, t3) = (t * t, t * t * t);
    0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
        + (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3)
}

impl SpectrumModule {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("spectrum-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(SPECTRUM_WGSL)),
        });
        let pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("spectrum-pl"),
            bind_group_layouts: &[],
            immediate_size: 0,
        });
        let vbl = wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<Vertex>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[
                wgpu::VertexAttribute { shader_location: 0, format: wgpu::VertexFormat::Float32x2, offset: 0 },
                wgpu::VertexAttribute {
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x4,
                    offset: std::mem::size_of::<[f32; 2]>() as u64,
                },
            ],
        };
        let geom_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("spectrum-geom-pipeline"),
            layout: Some(&pl),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[vbl],
                compilation_options: Default::default(),
            },
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState {
                    format,
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
            }),
            primitive: wgpu::PrimitiveState { topology: wgpu::PrimitiveTopology::TriangleList, ..Default::default() },
            depth_stencil: None,
            multisample: wgpu::MultisampleState { count: MSAA_SAMPLES, ..Default::default() },
            multiview_mask: None,
            cache: None,
        });

        // Composite pipeline: full-viewport triangle sampling the resolved offscreen 1:1.
        let comp_shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("spectrum-composite-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(COMPOSITE_WGSL)),
        });
        let composite_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("spectrum-composite-bgl"),
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
        let comp_pl = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("spectrum-composite-pl"),
            bind_group_layouts: &[Some(&composite_layout)],
            immediate_size: 0,
        });
        let composite_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("spectrum-composite-pipeline"),
            layout: Some(&comp_pl),
            vertex: wgpu::VertexState { module: &comp_shader, entry_point: Some("vs_main"), buffers: &[], compilation_options: Default::default() },
            fragment: Some(wgpu::FragmentState {
                module: &comp_shader,
                entry_point: Some("fs_main"),
                compilation_options: Default::default(),
                targets: &[Some(wgpu::ColorTargetState { format, blend: Some(wgpu::BlendState::ALPHA_BLENDING), write_mask: wgpu::ColorWrites::ALL })],
            }),
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });
        let sampler = device.create_sampler(&wgpu::SamplerDescriptor {
            label: Some("spectrum-sampler"),
            mag_filter: wgpu::FilterMode::Linear,
            min_filter: wgpu::FilterMode::Linear,
            ..Default::default()
        });

        let vbuf_cap = 1 << 16;
        let vbuf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("spectrum-vbuf"),
            size: (vbuf_cap * std::mem::size_of::<Vertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });
        let brush = BrushBuilder::using_font_bytes(FONT)
            .expect("embedded JetBrains Mono is a valid OFL TTF")
            .build(device, 256, 256, format);

        Self {
            geom_pipeline,
            composite_pipeline,
            composite_layout,
            sampler,
            format,
            offscreen: None,
            vbuf,
            vbuf_cap,
            verts: Vec::with_capacity(vbuf_cap),
            brush,
            brush_size: (0, 0),
            spectrum: None,
            display: SpectrumDisplay::new(0),
            sample_rate: 0.0,
            config: SpectrumConfig::default(),
        }
    }

    fn ensure_offscreen(&mut self, device: &wgpu::Device, w: u32, h: u32) {
        let (w, h) = (w.max(1), h.max(1));
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
        let msaa = make("spectrum-msaa", MSAA_SAMPLES, wgpu::TextureUsages::RENDER_ATTACHMENT);
        let resolved = make("spectrum-resolved", 1, wgpu::TextureUsages::RENDER_ATTACHMENT | wgpu::TextureUsages::TEXTURE_BINDING);
        let msaa_view = msaa.create_view(&Default::default());
        let resolved_view = resolved.create_view(&Default::default());
        let composite_bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("spectrum-composite-bg"),
            layout: &self.composite_layout,
            entries: &[
                wgpu::BindGroupEntry { binding: 0, resource: wgpu::BindingResource::TextureView(&resolved_view) },
                wgpu::BindGroupEntry { binding: 1, resource: wgpu::BindingResource::Sampler(&self.sampler) },
            ],
        });
        self.offscreen = Some(Offscreen { width: w, height: h, msaa_view, resolved_view, composite_bind_group });
    }

    /// A clip-space rectangle (`y0` bottom, `y1` top) as two triangles, per-corner colored (gradient).
    fn grad_quad(&mut self, x0: f32, x1: f32, y0: f32, y1: f32, c_bot: [f32; 4], c_top: [f32; 4]) {
        let (bl, br, tr, tl) = (v([x0, y0], c_bot), v([x1, y0], c_bot), v([x1, y1], c_top), v([x0, y1], c_top));
        self.verts.extend_from_slice(&[bl, br, tr, bl, tr, tl]);
    }
    fn line_quad(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, t: f32, c: [f32; 4]) {
        self.verts.extend_from_slice(&[
            v([x0, y0 - t], c), v([x1, y1 - t], c), v([x1, y1 + t], c),
            v([x0, y0 - t], c), v([x1, y1 + t], c), v([x0, y0 + t], c),
        ]);
    }

    /// Catmull-Rom interpolate a dB array into `(clip_x, dB)` dense points.
    fn smooth(vals: &[f32], xs: &[f32]) -> Vec<(f32, f32)> {
        let n = vals.len();
        let mut out = Vec::with_capacity(n * SUBDIV);
        for i in 0..n - 1 {
            let (p0, p1, p2, p3) =
                (vals[i.saturating_sub(1)], vals[i], vals[i + 1], vals[(i + 2).min(n - 1)]);
            for s in 0..SUBDIV {
                let t = s as f32 / SUBDIV as f32;
                out.push((xs[i] + (xs[i + 1] - xs[i]) * t, catmull(p0, p1, p2, p3, t)));
            }
        }
        out.push((xs[n - 1], vals[n - 1]));
        out
    }
}

impl Module for SpectrumModule {
    fn update(&mut self, ctx: &FrameContext, queue: &wgpu::Queue) {
        if ctx.sample_rate > 0.0 && (self.spectrum.is_none() || ctx.sample_rate != self.sample_rate) {
            self.sample_rate = ctx.sample_rate;
            let s = MultiResSpectrum::new(ctx.sample_rate as f64);
            self.display = SpectrumDisplay::new(s.n_points());
            self.spectrum = Some(s);
        }
        let mag: Vec<f32> = {
            let Some(spectrum) = self.spectrum.as_mut() else { return };
            for &[l, r] in ctx.new {
                spectrum.push((l + r) * 0.5);
            }
            spectrum.magnitudes_db().to_vec()
        };
        self.display.update(&mag, ctx.frame_dt as f32, self.config.attack_ms, self.config.release_ms);

        let floor = self.config.db_floor;
        let n = self.display.live.len();
        if n < 2 {
            return;
        }
        let xs: Vec<f32> = (0..n).map(|i| i as f32 / (n - 1) as f32 * 2.0 - 1.0).collect();
        let live = Self::smooth(&self.display.live, &xs);
        let peak = Self::smooth(&self.display.peak, &xs);
        self.verts.clear();

        // Grid (drawn first, under everything, MSAA-AA'd with the rest).
        let mut db = 0.0;
        while db > floor {
            let y = y_of_db(db, floor);
            self.grad_quad(-1.0, 1.0, y - 0.0012, y + 0.0012, GRID_RGBA, GRID_RGBA);
            db -= 20.0;
        }
        for (f, _) in FREQ_TICKS {
            if f > F_LO && f < F_HI {
                let x = x_of_freq(f);
                self.grad_quad(x - 0.001, x + 0.001, -1.0, 1.0, GRID_RGBA, GRID_RGBA);
            }
        }
        // Gradient fill: bright at the curve, transparent at the floor — its smooth top edge IS the
        // curve (no separate harsh outline).
        for w in live.windows(2) {
            let ((x0, d0), (x1, d1)) = (w[0], w[1]);
            let (y0, y1) = (y_of_db(d0, floor), y_of_db(d1, floor));
            // One trapezoid per segment: transparent at the floor, bright along the curve top.
            self.verts.extend_from_slice(&[
                v([x0, -1.0], FILL_BOT), v([x1, -1.0], FILL_BOT), v([x1, y1], FILL_TOP),
                v([x0, -1.0], FILL_BOT), v([x1, y1], FILL_TOP), v([x0, y0], FILL_TOP),
            ]);
        }
        // Peak overlay: a subtle line.
        for w in peak.windows(2) {
            let ((x0, d0), (x1, d1)) = (w[0], w[1]);
            self.line_quad(x0, y_of_db(d0, floor), x1, y_of_db(d1, floor), 0.0035, PEAK_RGBA);
        }

        if self.verts.len() > self.vbuf_cap {
            self.verts.truncate(self.vbuf_cap - self.vbuf_cap % 3);
        }
        queue.write_buffer(&self.vbuf, 0, bytemuck::cast_slice(&self.verts));
    }

    fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
        scale: f32,
    ) {
        let (w, h) = (viewport.w.max(1.0), viewport.h.max(1.0));

        // Text labels (drawn later in the host pass, over the composited spectrum).
        let size = (w as u32, h as u32);
        if size != self.brush_size {
            self.brush.resize_view(w, h, queue);
            self.brush_size = size;
        }
        let font = 11.0 * scale;
        let to_px_x = |cx: f32| (cx + 1.0) * 0.5 * w;
        let to_px_y = |cy: f32| (1.0 - cy) * 0.5 * h;
        let mut sections: Vec<Section> = Vec::new();
        for (f, lbl) in FREQ_TICKS {
            if f > F_LO && f < F_HI {
                sections.push(
                    Section::default()
                        .with_screen_position((to_px_x(x_of_freq(f)), h - 9.0 * scale))
                        .with_layout(Layout::default_single_line().h_align(HorizontalAlign::Center).v_align(VerticalAlign::Center))
                        .add_text(Text::new(lbl).with_scale(font).with_color(LABEL_RGBA)),
                );
            }
        }
        let mut db_labels: Vec<(f32, String)> = Vec::new();
        let mut db = 0.0;
        while db > self.config.db_floor + 1.0 {
            db_labels.push((db, format!("{db:.0}")));
            db -= 20.0;
        }
        for (db, s) in &db_labels {
            sections.push(
                Section::default()
                    .with_screen_position((4.0 * scale, to_px_y(y_of_db(*db, self.config.db_floor))))
                    .with_layout(Layout::default_single_line().v_align(VerticalAlign::Center))
                    .add_text(Text::new(s).with_scale(font).with_color(LABEL_RGBA)),
            );
        }
        let _ = self.brush.queue(device, queue, &sections);

        // Offscreen 4× MSAA pass: draw the geometry, resolved to single-sample (0007).
        if self.verts.is_empty() {
            return;
        }
        self.ensure_offscreen(device, w as u32, h as u32);
        let off = self.offscreen.as_ref().unwrap();
        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("spectrum-offscreen"),
            color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                view: &off.msaa_view,
                resolve_target: Some(&off.resolved_view),
                ops: wgpu::Operations { load: wgpu::LoadOp::Clear(wgpu::Color::TRANSPARENT), store: wgpu::StoreOp::Store },
                depth_slice: None,
            })],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });
        pass.set_pipeline(&self.geom_pipeline);
        pass.set_vertex_buffer(0, self.vbuf.slice(..));
        pass.draw(0..self.verts.len() as u32, 0..1);
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        if let Some(off) = &self.offscreen {
            if !self.verts.is_empty() {
                rpass.set_pipeline(&self.composite_pipeline);
                rpass.set_bind_group(0, &off.composite_bind_group, &[]);
                rpass.draw(0..3, 0..1);
            }
        }
        self.brush.draw(rpass);
    }

    fn on_event(&mut self, _event: &baseview::Event, _viewport: Rect) -> EventStatus {
        EventStatus::Ignored
    }

    fn save_config(&self) -> Vec<u8> {
        self.config.to_bytes()
    }
    fn load_config(&mut self, bytes: &[u8]) {
        self.config = SpectrumConfig::from_bytes(bytes);
    }
}

const SPECTRUM_WGSL: &str = r#"
struct VOut { @builtin(position) position: vec4<f32>, @location(0) color: vec4<f32> };
@vertex
fn vs_main(@location(0) p: vec2<f32>, @location(1) color: vec4<f32>) -> VOut {
    var o: VOut;
    o.position = vec4<f32>(p, 0.0, 1.0);
    o.color = color;
    return o;
}
@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> { return in.color; }
"#;

const COMPOSITE_WGSL: &str = r#"
struct VsOut { @builtin(position) clip: vec4<f32>, @location(0) uv: vec2<f32> };
@vertex
fn vs_main(@builtin(vertex_index) idx: u32) -> VsOut {
    var uv = vec2<f32>(f32((idx << 1u) & 2u), f32(idx & 2u));
    var o: VsOut;
    o.clip = vec4<f32>(uv * 2.0 - 1.0, 0.0, 1.0);
    o.uv = vec2<f32>(uv.x, 1.0 - uv.y);
    return o;
}
@group(0) @binding(0) var tex: texture_2d<f32>;
@group(0) @binding(1) var samp: sampler;
@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> { return textureSample(tex, samp, in.uv); }
"#;
