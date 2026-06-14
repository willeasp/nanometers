//! Stereometer Module — a goniometer of the stereo field (CONTEXT.md). The recent stereo samples are
//! plotted as a continuous **Lissajous line** in the mid/side plane (45° rotated, so mono collapses to
//! a vertical line, width spreads horizontally, L/R imbalance tilts it). The trace is age-faded along
//! its length — newest bright, oldest gone — and given a gentle ADDITIVE glow (the Oscilloscope's
//! instanced-layer trick, dialed down) so the line reads soft rather than razor-sharp. A faint diamond
//! + center line frame the full-scale bounds, and a −1..+1 phase-correlation meter (the shared
//! `nano-dsp` core) reads along the bottom.
//!
//! The strip is 1-D (column widths, full height), so the goniometer flexes and draws a CENTERED
//! SQUARE: an aspect uniform (`min(w,h)/w`, `min(w,h)/h`) scales the normalized [-1,1] plane so it
//! never stretches. The signal is additive (glow); the frame/meter/text are normal-blended (crisp).

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

/// Recent stereo frames in the trace — ~43 ms at 48 kHz. The age-fade emphasizes the newest, so a
/// longer ring just lengthens the (now very faint) tail.
const POINTS: usize = 2048;

/// Plot gain on the normalized mid/side coordinates. 1.0 makes the full-scale diamond the bound:
/// full-scale signals land ON the diamond, everything else inside it.
const GAIN: f32 = 1.0;

/// Additive glow instances for the signal: layer 0 is the crisp core, the rest a dim offset ring.
const GLOW_LAYERS: u32 = 5;

const SIGNAL_RGB: [f32; 3] = [0.45, 0.80, 1.0]; // the trace
const SIGNAL_ALPHA: f32 = 0.85; // newest-point alpha before the age-fade
const FRAME_RGBA: [f32; 4] = [0.24, 0.28, 0.36, 0.5]; // diamond + center line + meter track
const VALUE_RGBA: [f32; 4] = [0.55, 0.85, 1.0, 0.95]; // the correlation value tick
const TEXT_COLOR: [f32; 4] = [0.78, 0.84, 0.95, 1.0]; // the correlation number

/// Correlation meter geometry, in the normalized square: a track from −1..+1 along the bottom.
const METER_Y: f32 = -0.92;
const METER_HALF: f32 = 0.8; // track spans x ∈ [−METER_HALF, +METER_HALF]

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Vertex {
    pos: [f32; 2],
    color: [f32; 4],
}

#[repr(C)]
#[derive(Copy, Clone, Pod, Zeroable)]
struct Aspect {
    sx: f32,
    sy: f32,
    _pad: [f32; 2],
}

fn vtx(pos: [f32; 2], color: [f32; 4]) -> Vertex {
    Vertex { pos, color }
}

pub struct StereometerModule {
    /// Same shader; two pipelines differing only in blend — additive for the signal's glow, normal
    /// (over) for the crisp frame/meter.
    signal_pipeline: wgpu::RenderPipeline,
    ui_pipeline: wgpu::RenderPipeline,
    aspect_buf: wgpu::Buffer,
    bind_group: wgpu::BindGroup,

    signal_buf: wgpu::Buffer, // the Lissajous trace (rebuilt per frame), drawn as one LineStrip
    frame_buf: wgpu::Buffer,  // static: diamond, center line, meter track + center tick
    value_buf: wgpu::Buffer,  // the correlation value tick (rebuilt per frame)

    brush: Brush,
    brush_size: (u32, u32),

    ring: Box<[StereoFrame; POINTS]>,
    write_head: usize,
    scratch: Vec<Vertex>,

    correlation: Option<StereoCorrelation>,
    sample_rate: f32,
    corr_value: f32,
}

// Vertex offsets into `frame_buf` (built once in `new`): each disjoint LineStrip segment is its own draw.
const DIAMOND: std::ops::Range<u32> = 0..5;
const VLINE: std::ops::Range<u32> = 5..7;
const TRACK: std::ops::Range<u32> = 7..9;
const CENTER_TICK: std::ops::Range<u32> = 9..11;

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
        let aspect_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("stereometer-aspect"),
            contents: bytemuck::bytes_of(&Aspect { sx: 1.0, sy: 1.0, _pad: [0.0; 2] }),
            usage: wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        });
        let bind_group = device.create_bind_group(&wgpu::BindGroupDescriptor {
            label: Some("stereometer-bg"),
            layout: &bgl,
            entries: &[wgpu::BindGroupEntry { binding: 0, resource: aspect_buf.as_entire_binding() }],
        });

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
        // Additive (src.rgb*a + dst) so the glow layers sum into a soft bloom; normal "over" for the
        // crisp frame/meter.
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
            size: (POINTS * std::mem::size_of::<Vertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Static reference + meter rails.
        let frame_verts = vec![
            // diamond (closed LineStrip): top, right, bottom, left, top
            vtx([0.0, 1.0], FRAME_RGBA),
            vtx([1.0, 0.0], FRAME_RGBA),
            vtx([0.0, -1.0], FRAME_RGBA),
            vtx([-1.0, 0.0], FRAME_RGBA),
            vtx([0.0, 1.0], FRAME_RGBA),
            // mono center line
            vtx([0.0, 1.0], FRAME_RGBA),
            vtx([0.0, -1.0], FRAME_RGBA),
            // correlation track (−1 .. +1 along the bottom)
            vtx([-METER_HALF, METER_Y], FRAME_RGBA),
            vtx([METER_HALF, METER_Y], FRAME_RGBA),
            // track center mark (0 correlation = wide)
            vtx([0.0, METER_Y + 0.03], FRAME_RGBA),
            vtx([0.0, METER_Y - 0.03], FRAME_RGBA),
        ];
        let frame_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("stereometer-frame"),
            contents: bytemuck::cast_slice(&frame_verts),
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
            aspect_buf,
            bind_group,
            signal_buf,
            frame_buf,
            value_buf,
            brush,
            brush_size: (0, 0),
            ring: Box::new([[0.0; 2]; POINTS]),
            write_head: 0,
            scratch: vec![vtx([0.0; 2], [0.0; 4]); POINTS],
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

        // Rotate the ring into time order (oldest→newest) as Lissajous vertices: mid/side rotation
        // into the normalized plane, with a steep age-fade (newest opaque, the tail gone quickly).
        let denom = (POINTS - 1).max(1) as f32;
        for i in 0..POINTS {
            let frame = self.ring[(self.write_head + i) % POINTS];
            let (l, r) = (frame[0], frame[1]);
            let x = (r - l) * 0.5 * GAIN; // side
            let y = (l + r) * 0.5 * GAIN; // mid (up)
            let age = i as f32 / denom; // 0 = oldest, 1 = newest
            let alpha = age * age * age * SIGNAL_ALPHA; // steep fade
            self.scratch[i] = vtx([x, y], [SIGNAL_RGB[0], SIGNAL_RGB[1], SIGNAL_RGB[2], alpha]);
        }
        queue.write_buffer(&self.signal_buf, 0, bytemuck::cast_slice(&self.scratch));

        // The correlation value tick: +1 (mono) at the right end, −1 (anti) at the left.
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
        // Centered square: scale the normalized plane so the shorter dimension fills clip space.
        let s = viewport.w.min(viewport.h).max(1.0);
        let aspect = Aspect { sx: s / viewport.w.max(1.0), sy: s / viewport.h.max(1.0), _pad: [0.0; 2] };
        queue.write_buffer(&self.aspect_buf, 0, bytemuck::bytes_of(&aspect));

        // The correlation number, centered just under the meter track.
        let size = (viewport.w.max(1.0) as u32, viewport.h.max(1.0) as u32);
        if size != self.brush_size {
            self.brush.resize_view(size.0 as f32, size.1 as f32, queue);
            self.brush_size = size;
        }
        // METER_Y in normalized → viewport px: the square is centered, so y_px = h/2 - METER_Y*(s/2).
        let meter_y_px = viewport.h * 0.5 - METER_Y * s * 0.5 + 11.0 * scale;
        let text = format!("{:+.2}", self.corr_value);
        let section = Section::default()
            .with_screen_position((viewport.w * 0.5, meter_y_px))
            .with_layout(
                Layout::default_single_line()
                    .h_align(HorizontalAlign::Center)
                    .v_align(VerticalAlign::Center),
            )
            .add_text(Text::new(&text).with_scale(11.0 * scale).with_color(TEXT_COLOR));
        let _ = self.brush.queue(device, queue, &[section]);
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        // Crisp frame + meter (normal blend), under the glowing trace.
        rpass.set_pipeline(&self.ui_pipeline);
        rpass.set_bind_group(0, &self.bind_group, &[]);
        rpass.set_vertex_buffer(0, self.frame_buf.slice(..));
        rpass.draw(DIAMOND, 0..1);
        rpass.draw(VLINE, 0..1);
        rpass.draw(TRACK, 0..1);
        rpass.draw(CENTER_TICK, 0..1);
        rpass.set_vertex_buffer(0, self.value_buf.slice(..));
        rpass.draw(0..2, 0..1);

        // The Lissajous trace with its additive glow (GLOW_LAYERS instances).
        rpass.set_pipeline(&self.signal_pipeline);
        rpass.set_vertex_buffer(0, self.signal_buf.slice(..));
        rpass.draw(0..POINTS as u32, 0..GLOW_LAYERS);

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
struct Aspect { sx: f32, sy: f32, _p0: f32, _p1: f32 };
@group(0) @binding(0) var<uniform> a: Aspect;

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
    o.position = vec4<f32>(p.x * a.sx + off.x, p.y * a.sy + off.y, 0.0, 1.0);
    o.color = vec4<f32>(color.rgb, color.a * weight);
    return o;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
    return in.color;
}
"#;
