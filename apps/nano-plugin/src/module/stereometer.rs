//! Stereometer Module — a goniometer of the stereo field (CONTEXT.md). The recent stereo samples are
//! plotted as a continuous **Lissajous curve** in the mid/side plane (45° rotated, so mono collapses
//! to a vertical line, width spreads horizontally, L/R imbalance tilts it). The samples are
//! Catmull-Rom interpolated into a smooth curve, age-faded along its length (newest bright, oldest
//! gone), and given a gentle ADDITIVE glow so the line reads soft rather than razor-sharp. A faint
//! diamond + center line frame the full-scale bounds. Below the goniometer, a −1..+1 phase-correlation
//! meter (the shared `nano-dsp` core) reads along a reserved bottom band.
//!
//! The strip is 1-D (column widths, full height), so the goniometer flexes and draws a CENTERED
//! SQUARE in the area ABOVE the meter band: the `gonio` uniform (`sx, sy, oy`) scales+shifts the
//! normalized [-1,1] plane. The meter draws in raw clip space (an `identity` uniform) so it sits at
//! the bottom of the column regardless of the square's size. Signal = additive (glow); frame, meter,
//! and text = normal-blended (crisp).

use std::borrow::Cow;

use bytemuck::{Pod, Zeroable};
use nano_dsp::correlation::StereoCorrelation;
use wgpu::util::DeviceExt;
use wgpu_text::glyph_brush::ab_glyph::FontRef;
use wgpu_text::glyph_brush::{HorizontalAlign, Layout, Section, Text, VerticalAlign};
use wgpu_text::{BrushBuilder, TextBrush};

use super::{EventStatus, FrameContext, Module, Rect, FONT};
use crate::StereoFrame;

type Brush = TextBrush<FontRef<'static>>;

/// Recent stereo frames in the trace — ~43 ms at 48 kHz. The age-fade emphasizes the newest.
const POINTS: usize = 2048;
/// Catmull-Rom subdivisions per sample-to-sample segment — smooths the curve so low-frequency
/// trajectories don't show polygon angles.
const SUBDIV: usize = 5;
/// Interpolated vertices: `SUBDIV` per segment, plus the final endpoint.
const OUT_POINTS: usize = (POINTS - 1) * SUBDIV + 1;

/// Plot gain. 1.0 makes the full-scale diamond the bound — full-scale signals land on it, the rest
/// inside.
const GAIN: f32 = 1.0;
/// Fraction of the column height reserved at the BOTTOM for the correlation meter; the goniometer
/// square fills the area above it. Sized so the track clears the diamond above and the number below.
const BAND_FRAC: f32 = 0.18;
/// Additive glow instances for the signal: layer 0 is the crisp core, the rest a dim offset ring.
const GLOW_LAYERS: u32 = 5;

const SIGNAL_RGB: [f32; 3] = [0.45, 0.80, 1.0];
const SIGNAL_ALPHA: f32 = 0.85;
const FRAME_RGBA: [f32; 4] = [0.24, 0.28, 0.36, 0.5]; // diamond + center line + meter track
const VALUE_RGBA: [f32; 4] = [0.55, 0.85, 1.0, 0.95]; // the correlation value tick
const TEXT_COLOR: [f32; 4] = [0.78, 0.84, 0.95, 1.0];

/// Correlation meter, in raw clip space: a track in the UPPER part of the bottom band — high enough to
/// clear the number sitting at the very bottom edge.
const METER_Y: f32 = -0.78;
const METER_HALF: f32 = 0.82; // track spans clip x ∈ [−METER_HALF, +METER_HALF]

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 4],
}

/// `sx, sy` scale the normalized plane; `oy` shifts it up to clear the meter band.
#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Xform {
    sx: f32,
    sy: f32,
    oy: f32,
    _pad: f32,
}

fn vtx(pos: [f32; 2], color: [f32; 4]) -> Vertex {
    Vertex { pos, color }
}

/// Catmull-Rom point at parameter `t ∈ [0,1)` on the segment p1→p2 (p0,p3 are the neighbors).
fn catmull_rom(p0: [f32; 2], p1: [f32; 2], p2: [f32; 2], p3: [f32; 2], t: f32) -> [f32; 2] {
    let (t2, t3) = (t * t, t * t * t);
    let comp = |a: f32, b: f32, c: f32, d: f32| {
        0.5 * ((2.0 * b) + (-a + c) * t + (2.0 * a - 5.0 * b + 4.0 * c - d) * t2
            + (-a + 3.0 * b - 3.0 * c + d) * t3)
    };
    [comp(p0[0], p1[0], p2[0], p3[0]), comp(p0[1], p1[1], p2[1], p3[1])]
}

pub struct StereometerModule {
    signal_pipeline: wgpu::RenderPipeline, // additive (glow)
    ui_pipeline: wgpu::RenderPipeline,     // normal (crisp)
    gonio_buf: wgpu::Buffer,               // sx, sy, oy for the centered square (per frame)
    gonio_bg: wgpu::BindGroup,
    ident_bg: wgpu::BindGroup, // identity transform → raw clip space, for the meter

    signal_buf: wgpu::Buffer, // the interpolated Lissajous curve (per frame)
    frame_buf: wgpu::Buffer,  // static: diamond + center line (gonio space)
    meter_buf: wgpu::Buffer,  // static: correlation track + center tick (raw clip)
    value_buf: wgpu::Buffer,  // the correlation value tick (per frame, raw clip)

    brush: Brush,
    brush_size: (u32, u32),

    ring: Box<[StereoFrame; POINTS]>,
    write_head: usize,
    src: Box<[[f32; 2]; POINTS]>, // rotated source points, time-ordered
    scratch: Vec<Vertex>,         // interpolated output vertices

    correlation: Option<StereoCorrelation>,
    sample_rate: f32,
    corr_value: f32,
}

const DIAMOND: std::ops::Range<u32> = 0..5;
const VLINE: std::ops::Range<u32> = 5..7;
const TRACK: std::ops::Range<u32> = 0..2;
const CENTER_TICK: std::ops::Range<u32> = 2..4;

impl StereometerModule {
    pub fn new(device: &wgpu::Device, format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("stereometer-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(GONIO_WGSL)),
        });

        let bgl = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("stereometer-bgl"),
            entries: &[wgpu::BindGroupLayoutEntry {
                binding: 0,
                visibility: wgpu::ShaderStages::VERTEX,
                ty: wgpu::BindingType::Buffer {
                    ty: wgpu::BufferBindingType::Uniform,
                    has_dynamic_offset: false,
                    min_binding_size: None,
                },
                count: None,
            }],
        });
        let gonio_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("stereometer-gonio"),
            contents: bytemuck::bytes_of(&Xform { sx: 1.0, sy: 1.0, oy: 0.0, _pad: 0.0 }),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let ident_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("stereometer-ident"),
            contents: bytemuck::bytes_of(&Xform { sx: 1.0, sy: 1.0, oy: 0.0, _pad: 0.0 }),
            usage: wgpu::BufferUsages::UNIFORM,
        });
        let make_bg = |label: &str, buf: &wgpu::Buffer| {
            device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some(label),
                layout: &bgl,
                entries: &[wgpu::BindGroupEntry { binding: 0, resource: buf.as_entire_binding() }],
            })
        };
        let gonio_bg = make_bg("stereometer-gonio-bg", &gonio_buf);
        let ident_bg = make_bg("stereometer-ident-bg", &ident_buf);

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("stereometer-pl"),
            bind_group_layouts: &[Some(&bgl)],
            immediate_size: 0,
        });
        let vertex_layout = wgpu::VertexBufferLayout {
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
        let make_pipeline = |label: &str, blend: wgpu::BlendState| {
            device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
                label: Some(label),
                layout: Some(&pipeline_layout),
                vertex: wgpu::VertexState {
                    module: &shader,
                    entry_point: Some("vs_main"),
                    buffers: &[vertex_layout.clone()],
                    compilation_options: Default::default(),
                },
                fragment: Some(wgpu::FragmentState {
                    module: &shader,
                    entry_point: Some("fs_main"),
                    compilation_options: Default::default(),
                    targets: &[Some(wgpu::ColorTargetState {
                        format,
                        blend: Some(blend),
                        write_mask: wgpu::ColorWrites::ALL,
                    })],
                }),
                primitive: wgpu::PrimitiveState {
                    topology: wgpu::PrimitiveTopology::LineStrip,
                    ..Default::default()
                },
                depth_stencil: None,
                multisample: wgpu::MultisampleState::default(),
                multiview_mask: None,
                cache: None,
            })
        };
        let additive = wgpu::BlendState {
            color: wgpu::BlendComponent {
                src_factor: wgpu::BlendFactor::SrcAlpha,
                dst_factor: wgpu::BlendFactor::One,
                operation: wgpu::BlendOperation::Add,
            },
            alpha: wgpu::BlendComponent::OVER,
        };
        let signal_pipeline = make_pipeline("stereometer-signal-pipeline", additive);
        let ui_pipeline = make_pipeline("stereometer-ui-pipeline", wgpu::BlendState::ALPHA_BLENDING);

        let signal_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("stereometer-signal"),
            size: (OUT_POINTS * std::mem::size_of::<Vertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let frame_verts = vec![
            // diamond (closed LineStrip)
            vtx([0.0, 1.0], FRAME_RGBA),
            vtx([1.0, 0.0], FRAME_RGBA),
            vtx([0.0, -1.0], FRAME_RGBA),
            vtx([-1.0, 0.0], FRAME_RGBA),
            vtx([0.0, 1.0], FRAME_RGBA),
            // mono center line
            vtx([0.0, 1.0], FRAME_RGBA),
            vtx([0.0, -1.0], FRAME_RGBA),
        ];
        let frame_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("stereometer-frame"),
            contents: bytemuck::cast_slice(&frame_verts),
            usage: wgpu::BufferUsages::VERTEX,
        });
        // Meter rails in RAW clip space (ident transform): track across the bottom band, center mark.
        let meter_verts = vec![
            vtx([-METER_HALF, METER_Y], FRAME_RGBA),
            vtx([METER_HALF, METER_Y], FRAME_RGBA),
            vtx([0.0, METER_Y + 0.03], FRAME_RGBA),
            vtx([0.0, METER_Y - 0.03], FRAME_RGBA),
        ];
        let meter_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("stereometer-meter"),
            contents: bytemuck::cast_slice(&meter_verts),
            usage: wgpu::BufferUsages::VERTEX,
        });
        let value_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("stereometer-value"),
            size: (2 * std::mem::size_of::<Vertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        let brush = BrushBuilder::using_font_bytes(FONT)
            .expect("embedded JetBrains Mono is a valid OFL TTF")
            .build(device, 256, 256, format);

        Self {
            signal_pipeline,
            ui_pipeline,
            gonio_buf,
            gonio_bg,
            ident_bg,
            signal_buf,
            frame_buf,
            meter_buf,
            value_buf,
            brush,
            brush_size: (0, 0),
            ring: Box::new([[0.0; 2]; POINTS]),
            write_head: 0,
            src: Box::new([[0.0; 2]; POINTS]),
            scratch: vec![vtx([0.0; 2], [0.0; 4]); OUT_POINTS],
            correlation: None,
            sample_rate: 0.0,
            corr_value: 0.0,
        }
    }
}

impl Module for StereometerModule {
    fn update(&mut self, ctx: &FrameContext, queue: &wgpu::Queue) {
        if ctx.sample_rate > 0.0 && (self.correlation.is_none() || ctx.sample_rate != self.sample_rate)
        {
            self.sample_rate = ctx.sample_rate;
            self.correlation = Some(StereoCorrelation::new(ctx.sample_rate as f64));
        }

        for &frame in ctx.new {
            self.ring[self.write_head] = frame;
            self.write_head = (self.write_head + 1) % POINTS;
            if let Some(c) = self.correlation.as_mut() {
                c.push(frame[0], frame[1]);
            }
        }
        if let Some(c) = self.correlation.as_ref() {
            self.corr_value = c.value();
        }

        // Rotate the ring into time order (oldest→newest) as normalized mid/side points.
        for i in 0..POINTS {
            let frame = self.ring[(self.write_head + i) % POINTS];
            let (l, r) = (frame[0], frame[1]);
            self.src[i] = [(r - l) * 0.5 * GAIN, (l + r) * 0.5 * GAIN]; // side, mid(up)
        }

        // Catmull-Rom interpolate into a smooth curve; age-fade each output vertex (steep, so the tail
        // disappears fast).
        let out_denom = (OUT_POINTS - 1).max(1) as f32;
        let mut k = 0;
        for i in 0..POINTS - 1 {
            let p0 = self.src[i.saturating_sub(1)];
            let p1 = self.src[i];
            let p2 = self.src[i + 1];
            let p3 = self.src[(i + 2).min(POINTS - 1)];
            for s in 0..SUBDIV {
                let t = s as f32 / SUBDIV as f32;
                let pos = catmull_rom(p0, p1, p2, p3, t);
                let age = k as f32 / out_denom;
                let alpha = age * age * age * SIGNAL_ALPHA;
                self.scratch[k] = vtx(pos, [SIGNAL_RGB[0], SIGNAL_RGB[1], SIGNAL_RGB[2], alpha]);
                k += 1;
            }
        }
        self.scratch[k] =
            vtx(self.src[POINTS - 1], [SIGNAL_RGB[0], SIGNAL_RGB[1], SIGNAL_RGB[2], SIGNAL_ALPHA]);
        queue.write_buffer(&self.signal_buf, 0, bytemuck::cast_slice(&self.scratch));

        // Value tick (raw clip): +1 (mono) right, −1 (anti) left.
        let vx = self.corr_value.clamp(-1.0, 1.0) * METER_HALF;
        let value = [vtx([vx, METER_Y + 0.05], VALUE_RGBA), vtx([vx, METER_Y - 0.05], VALUE_RGBA)];
        queue.write_buffer(&self.value_buf, 0, bytemuck::cast_slice(&value));
    }

    fn prepare(
        &mut self,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
        scale: f32,
    ) {
        // Centered square in the area ABOVE the bottom meter band: side fits min(w, h·(1−band)); the
        // `oy` shift lifts it so the band below is clear.
        let (w, h) = (viewport.w.max(1.0), viewport.h.max(1.0));
        let s = w.min(h * (1.0 - BAND_FRAC));
        let xform = Xform { sx: s / w, sy: s / h, oy: BAND_FRAC, _pad: 0.0 };
        queue.write_buffer(&self.gonio_buf, 0, bytemuck::bytes_of(&xform));

        // The correlation number, centered just above the window's bottom edge.
        let size = (w as u32, h as u32);
        if size != self.brush_size {
            self.brush.resize_view(w, h, queue);
            self.brush_size = size;
        }
        let text = format!("{:+.2}", self.corr_value);
        let section = Section::default()
            .with_screen_position((w * 0.5, h - 10.0 * scale))
            .with_layout(
                Layout::default_single_line()
                    .h_align(HorizontalAlign::Center)
                    .v_align(VerticalAlign::Center),
            )
            .add_text(Text::new(&text).with_scale(11.0 * scale).with_color(TEXT_COLOR));
        let _ = self.brush.queue(device, queue, &[section]);
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        // Goniometer frame (gonio transform, normal blend).
        rpass.set_pipeline(&self.ui_pipeline);
        rpass.set_bind_group(0, &self.gonio_bg, &[]);
        rpass.set_vertex_buffer(0, self.frame_buf.slice(..));
        rpass.draw(DIAMOND, 0..1);
        rpass.draw(VLINE, 0..1);

        // The interpolated Lissajous curve with its additive glow.
        rpass.set_pipeline(&self.signal_pipeline);
        rpass.set_vertex_buffer(0, self.signal_buf.slice(..));
        rpass.draw(0..OUT_POINTS as u32, 0..GLOW_LAYERS);

        // Correlation meter (identity transform → raw clip, bottom band; normal blend).
        rpass.set_pipeline(&self.ui_pipeline);
        rpass.set_bind_group(0, &self.ident_bg, &[]);
        rpass.set_vertex_buffer(0, self.meter_buf.slice(..));
        rpass.draw(TRACK, 0..1);
        rpass.draw(CENTER_TICK, 0..1);
        rpass.set_vertex_buffer(0, self.value_buf.slice(..));
        rpass.draw(0..2, 0..1);

        self.brush.draw(rpass);
    }

    fn on_event(&mut self, _event: &baseview::Event, _viewport: Rect) -> EventStatus {
        EventStatus::Ignored
    }

    fn save_config(&self) -> Vec<u8> {
        Vec::new()
    }

    fn load_config(&mut self, _bytes: &[u8]) {}
}

const GONIO_WGSL: &str = r#"
struct Xform { sx: f32, sy: f32, oy: f32, _pad: f32 };
@group(0) @binding(0) var<uniform> u: Xform;

// Glow: layer 0 is the crisp core; the rest a dim ring offset around it (additive pipeline sums them
// into a soft bloom; the UI pipeline draws layer 0 only, crisp).
const GLOW_SPREAD: f32 = 0.006;
const GLOW_RING: f32 = 0.30;

struct VOut {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(
    @location(0) p: vec2<f32>,
    @location(1) color: vec4<f32>,
    @builtin(instance_index) layer: u32,
) -> VOut {
    var off = vec2<f32>(0.0, 0.0);
    var weight = 1.0;
    if (layer > 0u) {
        let ang = f32(layer) * 1.2566371; // 2π/5
        off = vec2<f32>(cos(ang), sin(ang)) * GLOW_SPREAD;
        weight = GLOW_RING;
    }
    var o: VOut;
    o.position = vec4<f32>(p.x * u.sx + off.x, p.y * u.sy + u.oy + off.y, 0.0, 1.0);
    o.color = vec4<f32>(color.rgb, color.a * weight);
    return o;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
    return in.color;
}
"#;
