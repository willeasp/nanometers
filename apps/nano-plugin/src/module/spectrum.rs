//! Spectrum Analyzer Module — a high-quality, exact, multi-resolution FFT spectrum (CONTEXT.md). The
//! DSP (three stitched FFTs, tone-exact at every frequency) lives in `nano_dsp::spectrum`; this module
//! runs the live + peak-hold ballistics over it and draws a smooth filled log-frequency / dB curve
//! with a peak overlay and a labeled grid. Response (release/attack) and the dB floor are persisted
//! config — the on-screen knobs (a later slice) tune them.

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
const DB_CEIL: f32 = 6.0; // a little headroom above 0 dBFS at the top

const FILL_RGBA: [f32; 4] = [0.30, 0.62, 0.95, 0.33];
const LINE_RGBA: [f32; 4] = [0.55, 0.82, 1.0, 0.95];
const PEAK_RGBA: [f32; 4] = [0.95, 0.85, 0.55, 0.85];
const GRID_RGBA: [f32; 4] = [0.30, 0.34, 0.42, 0.5];
const LABEL_RGBA: [f32; 4] = [0.55, 0.60, 0.70, 1.0];

const FREQ_TICKS: [(f32, &str); 8] =
    [(50.0, "50"), (100.0, "100"), (200.0, "200"), (500.0, "500"), (1000.0, "1k"), (2000.0, "2k"), (5000.0, "5k"), (10000.0, "10k")];

/// Persisted per-instance config (ADR 0003). The knobs write these; the DSP/display read them.
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

pub struct SpectrumModule {
    pipeline: wgpu::RenderPipeline,
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

/// log-frequency → clip x ∈ [-1, 1].
fn x_of_freq(f: f32) -> f32 {
    (f.max(F_LO).log2() - F_LO.log2()) / (F_HI.log2() - F_LO.log2()) * 2.0 - 1.0
}
/// dB → clip y ∈ [-1, 1] over [floor, DB_CEIL].
fn y_of_db(db: f32, floor: f32) -> f32 {
    (-1.0 + 2.0 * (db - floor) / (DB_CEIL - floor)).clamp(-1.0, 1.0)
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
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("spectrum-pipeline"),
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
            primitive: wgpu::PrimitiveState {
                topology: wgpu::PrimitiveTopology::TriangleList,
                ..Default::default()
            },
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            multiview_mask: None,
            cache: None,
        });

        let vbuf_cap = 1 << 16; // vertices; grown if needed
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
            pipeline,
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

    /// A thickness-`t` (clip units) quad — for lines drawn as triangles.
    fn quad(&mut self, x0: f32, y0: f32, x1: f32, y1: f32, color: [f32; 4]) {
        for p in [[x0, y0], [x1, y0], [x1, y1], [x0, y0], [x1, y1], [x0, y1]] {
            self.verts.push(v(p, color));
        }
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
        let Some(spectrum) = self.spectrum.as_mut() else { return };
        for &[l, r] in ctx.new {
            spectrum.push((l + r) * 0.5);
        }
        let mag = spectrum.magnitudes_db();
        self.display.update(mag, ctx.frame_dt as f32, self.config.attack_ms, self.config.release_ms);

        // Build geometry (all clip-space; the dB floor comes from config).
        let floor = self.config.db_floor;
        let n = self.display.live.len();
        if n < 2 {
            return;
        }
        let xs: Vec<f32> = (0..n).map(|i| i as f32 / (n - 1) as f32 * 2.0 - 1.0).collect();
        self.verts.clear();

        // Horizontal dB grid every 20 dB + labels handled in prepare.
        let mut db = 0.0;
        let yt = 0.0015;
        while db > floor {
            let y = y_of_db(db, floor);
            self.quad(-1.0, y - yt, 1.0, y + yt, GRID_RGBA);
            db -= 20.0;
        }
        // Vertical frequency grid.
        let xt = 0.0012;
        for (f, _) in FREQ_TICKS {
            if f > F_LO && f < F_HI {
                let x = x_of_freq(f);
                self.quad(x - xt, -1.0, x + xt, 1.0, GRID_RGBA);
            }
        }

        // Filled live curve: a quad per segment from the curve down to the floor.
        for i in 0..n - 1 {
            let (x0, x1) = (xs[i], xs[i + 1]);
            let y0 = y_of_db(self.display.live[i], floor);
            let y1 = y_of_db(self.display.live[i + 1], floor);
            self.verts.push(v([x0, -1.0], FILL_RGBA));
            self.verts.push(v([x1, -1.0], FILL_RGBA));
            self.verts.push(v([x1, y1], FILL_RGBA));
            self.verts.push(v([x0, -1.0], FILL_RGBA));
            self.verts.push(v([x1, y1], FILL_RGBA));
            self.verts.push(v([x0, y0], FILL_RGBA));
        }
        // Live line + peak line as thin vertical-thickness quads along each segment.
        let lt = 0.004;
        for i in 0..n - 1 {
            let (x0, x1) = (xs[i], xs[i + 1]);
            let (ya, yb) = (y_of_db(self.display.live[i], floor), y_of_db(self.display.live[i + 1], floor));
            self.quad(x0, ya - lt, x1, yb + lt, LINE_RGBA);
            let (pa, pb) = (y_of_db(self.display.peak[i], floor), y_of_db(self.display.peak[i + 1], floor));
            self.quad(x0, pa - lt, x1, pb + lt, PEAK_RGBA);
        }

        if self.verts.len() > self.vbuf_cap {
            self.verts.truncate(self.vbuf_cap);
        }
        queue.write_buffer(&self.vbuf, 0, bytemuck::cast_slice(&self.verts));
    }

    fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
        scale: f32,
    ) {
        let (w, h) = (viewport.w.max(1.0), viewport.h.max(1.0));
        let size = (w as u32, h as u32);
        if size != self.brush_size {
            self.brush.resize_view(w, h, queue);
            self.brush_size = size;
        }
        let font = 11.0 * scale;
        let to_px_x = |cx: f32| (cx + 1.0) * 0.5 * w;
        let to_px_y = |cy: f32| (1.0 - cy) * 0.5 * h;
        let mut sections: Vec<Section> = Vec::new();
        // Frequency labels along the bottom.
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
        // dB labels down the left (format the owned strings first so they outlive `sections`).
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
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        if !self.verts.is_empty() {
            rpass.set_pipeline(&self.pipeline);
            rpass.set_vertex_buffer(0, self.vbuf.slice(..));
            rpass.draw(0..self.verts.len() as u32, 0..1);
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
