//! Loudness Module (ADRs 0006 / 0005 + `docs/specs/loudness-module.md`).
//!
//! Wraps the hand-rolled BS.1770 DSP core (`crate::loudness::LoudnessDsp`, ebur128-verified) into a
//! GUI-side Module: fold each frame's samples in `update`, then draw the Momentary / Short-term /
//! Integrated time scales as three vertical bars (colored by level) with the numeric value above
//! and the label below each (text via `wgpu_text` + embedded OFL JetBrains Mono, ADR 0005).
//!
//! Channel weighting is load-bearing (spec): a mono stream must be measured as a SINGLE channel —
//! the plugin duplicates a mono input to L = R, so summing it reads +3 LU hot. `Channels` is
//! derived from `FrameContext::mono`.
//!
//! Geometry is emitted in plain [-1, 1] clip space and text in column-local pixels; the host's
//! `set_viewport` maps both into this Module's column.

use std::borrow::Cow;

use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt;
use wgpu_text::glyph_brush::ab_glyph::FontRef;
use wgpu_text::glyph_brush::{HorizontalAlign, Layout, Section, Text};
use wgpu_text::{BrushBuilder, TextBrush};

use super::{EventStatus, FrameContext, Module, Rect};
use crate::loudness::{Channels, LoudnessDsp};

/// Embedded OFL font (JetBrains Mono, tabular figures — values don't jitter as digits change).
const FONT: &[u8] = include_bytes!("../../assets/fonts/JetBrainsMono-Regular.ttf");

type Brush = TextBrush<FontRef<'static>>;

const VALUE_COLOR: [f32; 4] = [0.90, 0.94, 1.0, 1.0];

/// Bottom of the bar scale; loudness at or below this reads as an empty bar (dev-tuning).
const BAR_FLOOR_LUFS: f64 = -40.0;
const LABELS: [&str; 3] = ["M", "S", "I"];
/// Compact meter: three thin VERTICAL bars side by side (M/S/I), value above, label below.
/// Bars are a fixed pixel width regardless of column size; the rest is clip space (host
/// `set_viewport` maps it into the column).
const PX_BAR_W: f32 = 12.0; // bar width in px
const PX_BAR_PITCH: f32 = 24.0; // center-to-center spacing in px (tight side-by-side cluster)
const BAR_BASELINE_Y: f32 = 0.12; // clip-y bottom of bars (cluster sits in the upper area)
const BAR_TOP_Y: f32 = 0.86; // clip-y at full scale (near top)
const TRACK_COLOR: [f32; 3] = [0.16, 0.18, 0.22];
/// Per-frame smoothing toward the measured value so the bars/numbers ease instead of stepping
/// every 100 ms (visual ballistics; the DSP itself is exact).
const SMOOTH_ALPHA: f64 = 0.18;

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 3],
}

pub struct LoudnessModule {
    dsp: Option<LoudnessDsp>,
    sample_rate: f32,
    channels: Channels,

    brush: Brush,
    /// Current `resize_view` size, so we only re-project the brush when the viewport changes.
    brush_size: (u32, u32),

    bars_pipeline: wgpu::RenderPipeline,
    bars_vbuf: wgpu::Buffer,
    bars_vertex_count: u32,
    verts: Vec<Vertex>,

    /// Display values eased toward the measured M/S/I each frame (clamped to the bar floor when a
    /// scale has no measurement yet), so the readout glides instead of stepping every 100 ms.
    smoothed: [f64; 3],

    /// Frame counter for the optional `NANO_DEBUG_LOUDNESS` value log (dev aid, off by default).
    dbg_count: u32,
}

impl LoudnessModule {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        // Single-sample to match the host's shared pass (0007); format must equal the surface's.
        let brush = BrushBuilder::using_font_bytes(FONT)
            .expect("embedded JetBrains Mono is a valid OFL TTF")
            .build(device, 256, 256, format);

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("loudness-bars-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(BARS_WGSL)),
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("loudness-bars-pl"),
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
        let bars_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("loudness-bars-pipeline"),
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
                    blend: None,
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

        // 3 rows × (track + fill) × 6 vertices.
        let bars_vbuf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("loudness-bars-vbuf"),
            contents: &vec![0u8; 36 * std::mem::size_of::<Vertex>()],
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
        });

        Self {
            dsp: None,
            sample_rate: 0.0,
            channels: Channels::Stereo,
            brush,
            brush_size: (256, 256),
            bars_pipeline,
            bars_vbuf,
            bars_vertex_count: 0,
            verts: Vec::with_capacity(36),
            smoothed: [BAR_FLOOR_LUFS; 3],
            dbg_count: 0,
        }
    }

    /// Push a clip-space rectangle (two triangles) into the vertex scratch.
    fn push_quad(&mut self, x0: f32, x1: f32, y0: f32, y1: f32, color: [f32; 3]) {
        for pos in [[x0, y0], [x1, y0], [x1, y1], [x0, y0], [x1, y1], [x0, y1]] {
            self.verts.push(Vertex { pos, color });
        }
    }
}

/// Map a loudness value to a bar fill fraction in `[0, 1]`: `BAR_FLOOR_LUFS` → 0, `0 LUFS` → 1.
/// Non-finite (no measurement yet) → 0 (empty bar).
fn bar_fraction(lufs: f64) -> f32 {
    if !lufs.is_finite() {
        return 0.0;
    }
    (((lufs - BAR_FLOOR_LUFS) / (0.0 - BAR_FLOOR_LUFS)) as f32).clamp(0.0, 1.0)
}

/// Bar color by fill level: calm green when low, through amber, to hot red as it approaches 0 LUFS.
fn bar_rgb(frac: f32) -> [f32; 3] {
    let lerp = |a: f32, b: f32, t: f32| a + (b - a) * t;
    if frac < 0.6 {
        let t = frac / 0.6;
        [lerp(0.22, 0.85, t), lerp(0.74, 0.78, t), lerp(0.42, 0.25, t)]
    } else {
        let t = ((frac - 0.6) / 0.4).clamp(0.0, 1.0);
        [lerp(0.85, 0.93, t), lerp(0.78, 0.28, t), lerp(0.25, 0.22, t)]
    }
}

fn fmt_value(v: f64) -> String {
    if v.is_finite() {
        format!("{v:.1}")
    } else {
        "--.-".to_string()
    }
}

/// The eased value once a scale has a measurement, dashes until then.
fn value_text(smoothed: f64, target: f64) -> String {
    if target.is_finite() {
        fmt_value(smoothed)
    } else {
        "--.-".to_string()
    }
}

impl Module for LoudnessModule {
    fn update(&mut self, ctx: &FrameContext, _queue: &wgpu::Queue) {
        if ctx.sample_rate <= 0.0 {
            return; // unknown rate — meter idles (spec)
        }
        let channels = if ctx.mono {
            Channels::Mono
        } else {
            Channels::Stereo
        };
        if self.dsp.is_none() || ctx.sample_rate != self.sample_rate || channels != self.channels {
            self.sample_rate = ctx.sample_rate;
            self.channels = channels;
            self.dsp = Some(LoudnessDsp::new(ctx.sample_rate as f64, channels));
        }
        if let Some(dsp) = self.dsp.as_mut() {
            for &[l, r] in ctx.new {
                dsp.push_frame(l, r);
            }
        }

        // Dev aid (off by default): log live values so the meter can be verified even when a
        // system overlay hides the on-screen text. Throttled to ~once/2s at 60 fps.
        self.dbg_count = self.dbg_count.wrapping_add(1);
        if self.dbg_count % 120 == 0 && std::env::var_os("NANO_DEBUG_LOUDNESS").is_some() {
            if let Some(dsp) = self.dsp.as_ref() {
                eprintln!(
                    "[loudness] M={:.1} S={:.1} I={:.1} LUFS ({:?})",
                    dsp.momentary_lufs(),
                    dsp.short_term_lufs(),
                    dsp.integrated_lufs(),
                    self.channels
                );
            }
        }
    }

    fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
    ) {
        // Re-project the brush onto the viewport when its size changes.
        let size = (viewport.w.max(1.0) as u32, viewport.h.max(1.0) as u32);
        if size != self.brush_size {
            self.brush.resize_view(size.0 as f32, size.1 as f32, queue);
            self.brush_size = size;
        }

        // Measured targets; missing scales drive the smoother toward the floor so the bar eases
        // empty rather than snapping. The DSP value itself stays exact.
        let targets = self
            .dsp
            .as_ref()
            .map(|d| [d.momentary_lufs(), d.short_term_lufs(), d.integrated_lufs()])
            .unwrap_or([f64::NEG_INFINITY; 3]);
        for k in 0..3 {
            let t = if targets[k].is_finite() { targets[k] } else { BAR_FLOOR_LUFS };
            self.smoothed[k] += (t - self.smoothed[k]) * SMOOTH_ALPHA;
        }

        // Three thin VERTICAL bars side by side, centered: a faint full-height track + a colored
        // fill rising from the baseline by the level fraction.
        let half_w = PX_BAR_W / viewport.w; // clip half-width for a PX_BAR_W-px bar
        let center_px = |k: usize| viewport.w * 0.5 + (k as f32 - 1.0) * PX_BAR_PITCH;
        self.verts.clear();
        for k in 0..3 {
            let frac = bar_fraction(self.smoothed[k]);
            let cx = center_px(k) / viewport.w * 2.0 - 1.0;
            let (x0, x1) = (cx - half_w, cx + half_w);
            self.push_quad(x0, x1, BAR_BASELINE_Y, BAR_TOP_Y, TRACK_COLOR);
            let top = BAR_BASELINE_Y + frac * (BAR_TOP_Y - BAR_BASELINE_Y);
            if top > BAR_BASELINE_Y {
                self.push_quad(x0, x1, BAR_BASELINE_Y, top, bar_rgb(frac));
            }
        }
        queue.write_buffer(&self.bars_vbuf, 0, bytemuck::cast_slice(&self.verts));
        self.bars_vertex_count = self.verts.len() as u32;

        // Readable "label  value" rows stacked below the bar cluster (bigger text — the bars are
        // the compact part, the numbers should be legible). Centered, M/S/I top→bottom matching the
        // bars left→right.
        let value_scale = (viewport.w * 0.17).clamp(15.0, 30.0);
        let rows_y = [0.55f32, 0.71, 0.87];
        let strs: [String; 3] = [
            format!("{}  {}", LABELS[0], value_text(self.smoothed[0], targets[0])),
            format!("{}  {}", LABELS[1], value_text(self.smoothed[1], targets[1])),
            format!("{}  {}", LABELS[2], value_text(self.smoothed[2], targets[2])),
        ];
        let cx = viewport.w * 0.5;
        let mut sections: Vec<Section> = Vec::with_capacity(3);
        for k in 0..3 {
            sections.push(
                Section::default()
                    .with_screen_position((cx, viewport.h * rows_y[k]))
                    .with_layout(Layout::default_single_line().h_align(HorizontalAlign::Center))
                    .add_text(Text::new(&strs[k]).with_scale(value_scale).with_color(VALUE_COLOR)),
            );
        }
        let _ = self.brush.queue(device, queue, &sections);
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        if self.bars_vertex_count > 0 {
            rpass.set_pipeline(&self.bars_pipeline);
            rpass.set_vertex_buffer(0, self.bars_vbuf.slice(..));
            rpass.draw(0..self.bars_vertex_count, 0..1);
        }
        self.brush.draw(rpass);
    }

    fn on_event(&mut self, _event: &baseview::Event, _viewport: Rect) -> EventStatus {
        EventStatus::Ignored // reset affordance lands in Phase E
    }

    fn save_config(&self) -> Vec<u8> {
        Vec::new() // opaque config (target/scale) lands in Phase F
    }

    fn load_config(&mut self, _bytes: &[u8]) {}
}

const BARS_WGSL: &str = r#"
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

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bar_fraction_maps_floor_to_zero_and_full_scale_to_one() {
        assert_eq!(bar_fraction(0.0), 1.0);
        assert_eq!(bar_fraction(BAR_FLOOR_LUFS), 0.0);
        assert!((bar_fraction(-20.0) - 0.5).abs() < 1e-6);
    }

    #[test]
    fn bar_fraction_clamps_and_handles_silence() {
        assert_eq!(bar_fraction(10.0), 1.0); // above 0 LUFS clamps to full
        assert_eq!(bar_fraction(-100.0), 0.0); // below floor clamps to empty
        assert_eq!(bar_fraction(f64::NEG_INFINITY), 0.0); // no measurement → empty
    }

    #[test]
    fn fmt_value_finite_and_silent() {
        assert_eq!(fmt_value(-14.2), "-14.2");
        assert_eq!(fmt_value(f64::NEG_INFINITY), "--.-");
    }
}
