//! Loudness Module (ADRs 0006 / 0005 + `docs/specs/loudness-module.md`).
//!
//! Wraps the hand-rolled BS.1770 DSP core (`crate::loudness::LoudnessDsp`, ebur128-verified) into a
//! GUI-side Module: fold each frame's samples in `update`, then draw the Momentary / Short-term /
//! Integrated time scales as three tall vertical bars (colored by level) against an absolute-LUFS
//! grid (3 dB steps, numbered down the left), each bar captioned with its letter + LUFS value below
//! (text via `wgpu_text` + the embedded OFL JetBrains Mono, ADR 0005).
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
use wgpu_text::glyph_brush::{HorizontalAlign, Layout, Section, Text, VerticalAlign};
use wgpu_text::{BrushBuilder, TextBrush};

use super::{EventStatus, FrameContext, Module, Rect};
use crate::loudness::{Channels, LoudnessDsp};

/// Embedded OFL font (JetBrains Mono, tabular figures — values don't jitter as digits change).
const FONT: &[u8] = include_bytes!("../../assets/fonts/JetBrainsMono-Regular.ttf");

type Brush = TextBrush<FontRef<'static>>;

const VALUE_COLOR: [f32; 4] = [0.90, 0.94, 1.0, 1.0]; // the LUFS number under each bar
const LABEL_COLOR: [f32; 4] = [0.60, 0.66, 0.78, 1.0]; // the M / S / I letter under each bar
const SCALE_LABEL_COLOR: [f32; 4] = [0.55, 0.60, 0.70, 1.0]; // the scale numbers down the left
const GRID_COLOR: [f32; 3] = [0.27, 0.30, 0.36]; // faint gridline behind the bars

/// The bar scale runs `0 LUFS` (top) → `BAR_FLOOR_LUFS` (baseline); at/below the floor the bar empties.
const BAR_FLOOR_LUFS: f64 = -40.0;
const LABELS: [&str; 3] = ["M", "S", "I"];

// ── Layout knobs (LOGICAL px) ──────────────────────────────────────────────────────────────────────
// These are the ONLY hand-set sizes. Everything positional — the scale gutter, the readout width, the
// bar pitch, and the module's total width — is DERIVED in `hlayout()`, so a single edit reflows the
// whole module and the layout's fixed column width (via `intrinsic_width`) stays in sync automatically.
const TEXT_PX: f32 = 12.0; // all text: scale numbers, readouts, and the M/S/I letters
const GLYPH_ADV: f32 = 0.6; // JetBrains Mono advance per glyph, as a fraction of the font size
const SCALE_CHARS: f32 = 3.0; // widest scale number ("-40")
const VALUE_CHARS: f32 = 5.0; // widest readout ("-17.5")
const PAD: f32 = 4.0; // outer padding (all sides)
const SCALE_GAP: f32 = 4.0; // gap from the scale numbers to the bar cluster
const READOUT_GAP: f32 = 5.0; // gap between adjacent readouts — this sets the bar pitch
const BAR_FILL: f32 = 0.55; // bar width as a fraction of a readout's width (slim < 1.0)
const CAPTION_GAP: f32 = 4.0; // gap from the bar baseline down to the caption
const LINE_H: f32 = 1.2; // text line height as a multiple of the font size (letter → value below it)
const GRID_PX_H: f32 = 1.0; // gridline thickness

/// Height of the caption strip below the bars: the gap plus two LINE_H-tall text lines (the letter,
/// the value under it). Derived from the caption's own knobs so retuning TEXT_PX/LINE_H reflows the
/// strip — LINE_H's 20% headroom over the em covers the value line's descenders.
fn caption_h() -> f32 {
    CAPTION_GAP + 2.0 * TEXT_PX * LINE_H
}

/// Scale ticks in 3 dB steps, in absolute LUFS — 0 down to the floor, which closes the bottom. (Not
/// "LU": per `CONTEXT.md`, LU is a difference relative to a Target — that display is Phase F config.)
/// Drawn as faint gridlines behind the bars with a number on the left (spec §Purpose). `MAX_VERTS`,
/// the scratch `Vec`, and the text all track this list, so editing it is the only change to retune it.
const SCALE_TICKS: [f64; 14] = [
    0.0, -3.0, -6.0, -9.0, -12.0, -15.0, -18.0, -21.0, -24.0, -27.0, -30.0, -33.0, -36.0,
    BAR_FLOOR_LUFS,
];

/// Vertex-buffer capacity: 3 bar fills + one quad per scale gridline, × 6 verts/quad.
const MAX_VERTS: usize = (3 + SCALE_TICKS.len()) * 6;

/// Per-frame smoothing toward the measured value so the bars/numbers ease instead of stepping every
/// 100 ms (visual ballistics; the DSP itself is exact).
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

    /// The scale-tick numbers, formatted once at construction — `SCALE_TICKS` is const, so
    /// re-formatting them every frame would be pure allocation churn on the render path.
    tick_labels: Vec<String>,

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

        // Sized to MAX_VERTS: 3 bar fills + one quad per scale gridline.
        let bars_vbuf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("loudness-bars-vbuf"),
            contents: &vec![0u8; MAX_VERTS * std::mem::size_of::<Vertex>()],
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
            verts: Vec::with_capacity(MAX_VERTS),
            smoothed: [BAR_FLOOR_LUFS; 3],
            tick_labels: SCALE_TICKS.iter().map(|t| format!("{}", *t as i32)).collect(),
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

/// The module's intrinsic horizontal layout, in LOGICAL px — the single source of truth shared by
/// `prepare` (each field × DPI) and `layout::default_layout` (via [`intrinsic_width`]). Everything is
/// derived from the layout knobs above, so nothing is hand-synced.
struct HLayout {
    width: f32,         // total module width
    numbers_right: f32, // x where the right-aligned scale numbers end
    cluster_left: f32,  // left edge of the leftmost readout
    value_w: f32,       // a readout's width
    pitch: f32,         // readout / bar center-to-center
    bar_w: f32,         // a bar's width
}

fn hlayout() -> HLayout {
    let gutter = TEXT_PX * SCALE_CHARS * GLYPH_ADV; // scale-number column, fits "-40"
    let value_w = TEXT_PX * VALUE_CHARS * GLYPH_ADV; // a readout, fits "-17.5"
    let pitch = value_w + READOUT_GAP;
    let numbers_right = PAD + gutter;
    let cluster_left = numbers_right + SCALE_GAP;
    let cluster_w = value_w + 2.0 * pitch; // leftmost readout's left edge → rightmost readout's right edge
    HLayout {
        width: cluster_left + cluster_w + PAD,
        numbers_right,
        cluster_left,
        value_w,
        pitch,
        bar_w: value_w * BAR_FILL,
    }
}

/// The fixed logical width this module wants in the strip (`layout::default_layout` pins it here).
pub fn intrinsic_width() -> f32 {
    hlayout().width
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
    fn intrinsic_width(&self) -> Option<f32> {
        Some(hlayout().width)
    }

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
        scale: f32,
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

        // ---- horizontal layout: the derived logical layout (one source of truth), scaled to px ----
        let s = scale; // physical px per logical px (2.0 on a Retina panel)
        let (w, h) = (viewport.w, viewport.h);
        let hl = hlayout();
        let numbers_right = hl.numbers_right * s;
        let cluster_left = hl.cluster_left * s;
        let value_w = hl.value_w * s;
        let pitch = hl.pitch * s;
        let bar_w = hl.bar_w * s;
        let bar_mid = |k: usize| cluster_left + value_w * 0.5 + k as f32 * pitch;

        // Vertical: bars fill the column down to a bottom caption strip.
        let pad = PAD * s;
        let bars_top = pad;
        let bars_bottom = (h - pad - caption_h() * s).max(bars_top + 1.0);
        let bar_span = bars_bottom - bars_top;

        // px → clip: x in [-1, 1] over the width; y flips (screen top-down → clip y-up).
        let cx = |px: f32| px / w * 2.0 - 1.0;
        let cy = |px: f32| 1.0 - px / h * 2.0;
        // A loudness level → screen-y in the bar area (floor → baseline, 0 LUFS → top).
        let level_y = |lufs: f64| bars_bottom - bar_fraction(lufs) * bar_span;

        self.verts.clear();

        // 1) Scale gridlines at each tick, BEHIND the bars (leftmost bar's edge → rightmost bar's edge).
        // Drawn UNDER the fills, so a rising fill swallows them bottom-up; each sits at its level.
        let grid_left = bar_mid(0) - bar_w * 0.5;
        let grid_right = bar_mid(2) + bar_w * 0.5;
        let grid_half_h = GRID_PX_H * s * 0.5;
        for &tick in &SCALE_TICKS {
            let y = level_y(tick);
            self.push_quad(
                cx(grid_left),
                cx(grid_right),
                cy(y + grid_half_h),
                cy(y - grid_half_h),
                GRID_COLOR,
            );
        }

        // 2) Bar fills over the gridlines.
        for k in 0..3 {
            let frac = bar_fraction(self.smoothed[k]);
            if frac > 0.0 {
                let mid = bar_mid(k);
                self.push_quad(
                    cx(mid - bar_w * 0.5),
                    cx(mid + bar_w * 0.5),
                    cy(bars_bottom),
                    cy(level_y(self.smoothed[k])),
                    bar_rgb(frac),
                );
            }
        }
        queue.write_buffer(&self.bars_vbuf, 0, bytemuck::cast_slice(&self.verts));
        self.bars_vertex_count = self.verts.len() as u32;

        // ---- text (all at TEXT_PX × DPI): scale numbers in the gutter, M/S/I caption under each bar ----
        let font = TEXT_PX * s;
        let mut sections: Vec<Section> = Vec::with_capacity(2 * 3 + SCALE_TICKS.len());

        // Scale numbers: right-aligned at the gutter edge, vertically centered on each gridline.
        for (tick, label) in SCALE_TICKS.iter().zip(self.tick_labels.iter()) {
            sections.push(
                Section::default()
                    .with_screen_position((numbers_right, level_y(*tick)))
                    .with_layout(
                        Layout::default_single_line()
                            .h_align(HorizontalAlign::Right)
                            .v_align(VerticalAlign::Center),
                    )
                    .add_text(Text::new(label).with_scale(font).with_color(SCALE_LABEL_COLOR)),
            );
        }

        // Caption under each bar: the letter, then the LUFS value below it, centered on the bar.
        let letter_y = bars_bottom + CAPTION_GAP * s;
        let value_y = letter_y + font * LINE_H;
        let values: [String; 3] = [
            value_text(self.smoothed[0], targets[0]),
            value_text(self.smoothed[1], targets[1]),
            value_text(self.smoothed[2], targets[2]),
        ];
        for k in 0..3 {
            let mid = bar_mid(k);
            sections.push(
                Section::default()
                    .with_screen_position((mid, letter_y))
                    .with_layout(Layout::default_single_line().h_align(HorizontalAlign::Center))
                    .add_text(Text::new(LABELS[k]).with_scale(font).with_color(LABEL_COLOR)),
            );
            sections.push(
                Section::default()
                    .with_screen_position((mid, value_y))
                    .with_layout(Layout::default_single_line().h_align(HorizontalAlign::Center))
                    .add_text(Text::new(&values[k]).with_scale(font).with_color(VALUE_COLOR)),
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

    #[test]
    fn scale_ticks_span_the_floor_range_top_down() {
        // Ticks run top→bottom (0 LUFS first, floor last) and every one sits on the drawn scale.
        assert_eq!(SCALE_TICKS[0], 0.0);
        assert_eq!(*SCALE_TICKS.last().unwrap(), BAR_FLOOR_LUFS);
        for w in SCALE_TICKS.windows(2) {
            assert!(w[0] > w[1], "ticks must descend: {} !> {}", w[0], w[1]);
        }
        for &t in &SCALE_TICKS {
            assert!((BAR_FLOOR_LUFS..=0.0).contains(&t), "tick {t} within [-40, 0]");
        }
    }
}
