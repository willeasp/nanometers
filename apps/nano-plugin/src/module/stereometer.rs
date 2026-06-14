//! Stereometer Module — a goniometer of the stereo field (CONTEXT.md). The recent stereo samples are
//! plotted as a continuous **Lissajous line** in the mid/side plane (45° rotated, so mono collapses to
//! a vertical line, width spreads horizontally, L/R imbalance tilts it). The trace is age-faded along
//! its length — newest bright, oldest dim — with NORMAL alpha blending (no additive glow), so it's a
//! clean single line rather than the Oscilloscope's glow stack. A faint diamond + center line frame
//! the full-scale bounds. A −1..+1 phase-correlation meter (the shared `nano-dsp` core) reads below.
//!
//! The strip is 1-D (column widths, full height), so the goniometer flexes and draws a CENTERED
//! SQUARE: an aspect uniform (`min(w,h)/w`, `min(w,h)/h`) scales the normalized [-1,1] plane so it
//! never stretches.

use std::borrow::Cow;

use bytemuck::{Pod, Zeroable};
use nano_dsp::correlation::StereoCorrelation;
use wgpu::util::DeviceExt;

use super::{EventStatus, FrameContext, Module, Rect};
use crate::StereoFrame;

/// Recent stereo frames in the trace — ~43 ms at 48 kHz. The age-fade emphasizes the newest, so a
/// longer ring just lengthens the faint tail.
const POINTS: usize = 2048;

/// Plot gain on the normalized mid/side coordinates. >1 lifts typical (sub-full-scale) material to
/// fill the diamond; the loudest peaks clip at the square edge. Tuned by eye.
const GAIN: f32 = 1.5;

const SIGNAL_RGB: [f32; 3] = [0.55, 0.85, 1.0]; // the trace
const FRAME_RGBA: [f32; 4] = [0.26, 0.30, 0.38, 0.55]; // the diamond + center line

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

pub struct StereometerModule {
    pipeline: wgpu::RenderPipeline,
    aspect_buf: wgpu::Buffer,
    bind_group: wgpu::BindGroup,

    /// The Lissajous trace (rebuilt every frame), drawn as one LineStrip.
    signal_buf: wgpu::Buffer,
    /// The full-scale diamond + center line (static), drawn as a LineStrip + a 2-vertex line.
    frame_buf: wgpu::Buffer,
    frame_diamond_verts: u32,
    frame_total_verts: u32,

    // Ingest: most recent POINTS stereo frames as a ring, rotated to time order each frame.
    ring: Box<[StereoFrame; POINTS]>,
    write_head: usize,
    scratch: Vec<Vertex>,

    // Phase-correlation (shared nano-dsp core); re-created on a sample-rate change. Drawn in a later
    // slice — fed here so the value is ready.
    correlation: Option<StereoCorrelation>,
    sample_rate: f32,
    corr_value: f32,
}

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
                wgpu::VertexAttribute {
                    shader_location: 0,
                    format: wgpu::VertexFormat::Float32x2,
                    offset: 0,
                },
                wgpu::VertexAttribute {
                    shader_location: 1,
                    format: wgpu::VertexFormat::Float32x4,
                    offset: std::mem::size_of::<[f32; 2]>() as u64,
                },
            ],
        };
        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("stereometer-pipeline"),
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
                    // NORMAL alpha blend (src.rgb*a + dst*(1-a)) — a clean line, NOT additive glow.
                    blend: Some(wgpu::BlendState {
                        color: wgpu::BlendComponent {
                            src_factor: wgpu::BlendFactor::SrcAlpha,
                            dst_factor: wgpu::BlendFactor::OneMinusSrcAlpha,
                            operation: wgpu::BlendOperation::Add,
                        },
                        alpha: wgpu::BlendComponent::OVER,
                    }),
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
        });

        let signal_buf = device.create_buffer(&wgpu::BufferDescriptor {
            label: Some("stereometer-signal"),
            size: (POINTS * std::mem::size_of::<Vertex>()) as u64,
            usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            mapped_at_creation: false,
        });

        // Static reference: the full-scale diamond (5-vertex closed LineStrip), then the mono center
        // line (2 vertices). Two draws over one buffer, split at `frame_diamond_verts`.
        let diamond = [[0.0, 1.0], [1.0, 0.0], [0.0, -1.0], [-1.0, 0.0], [0.0, 1.0]];
        let vline = [[0.0, 1.0], [0.0, -1.0]];
        let frame_verts: Vec<Vertex> = diamond
            .iter()
            .chain(vline.iter())
            .map(|&pos| Vertex { pos, color: FRAME_RGBA })
            .collect();
        let frame_buf = device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
            label: Some("stereometer-frame"),
            contents: bytemuck::cast_slice(&frame_verts),
            usage: wgpu::BufferUsages::VERTEX,
        });

        Self {
            pipeline,
            aspect_buf,
            bind_group,
            signal_buf,
            frame_buf,
            frame_diamond_verts: diamond.len() as u32,
            frame_total_verts: frame_verts.len() as u32,
            ring: Box::new([[0.0; 2]; POINTS]),
            write_head: 0,
            scratch: vec![Vertex { pos: [0.0; 2], color: [0.0; 4] }; POINTS],
            correlation: None,
            sample_rate: 0.0,
            corr_value: 0.0,
        }
    }
}

impl Module for StereometerModule {
    fn update(&mut self, ctx: &FrameContext, queue: &wgpu::Queue) {
        // (Re)create the correlation core on a sample-rate change.
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
        // into the normalized plane, age-faded alpha (newest opaque → oldest faint).
        let denom = (POINTS - 1).max(1) as f32;
        for i in 0..POINTS {
            let frame = self.ring[(self.write_head + i) % POINTS];
            let (l, r) = (frame[0], frame[1]);
            let x = (r - l) * 0.5 * GAIN; // side
            let y = (l + r) * 0.5 * GAIN; // mid (up)
            let age = i as f32 / denom; // 0 = oldest, 1 = newest
            let alpha = age * age; // emphasize the recent trace, faint tail
            self.scratch[i] = Vertex { pos: [x, y], color: [SIGNAL_RGB[0], SIGNAL_RGB[1], SIGNAL_RGB[2], alpha] };
        }
        queue.write_buffer(&self.signal_buf, 0, bytemuck::cast_slice(&self.scratch));
    }

    fn prepare(
        &mut self,
        _device: &wgpu::Device,
        queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        viewport: Rect,
        _scale: f32,
    ) {
        // Centered square: scale the normalized plane so the shorter dimension fills clip space and
        // the longer one is letterboxed — the goniometer never stretches.
        let s = viewport.w.min(viewport.h).max(1.0);
        let aspect = Aspect { sx: s / viewport.w.max(1.0), sy: s / viewport.h.max(1.0), _pad: [0.0; 2] };
        queue.write_buffer(&self.aspect_buf, 0, bytemuck::bytes_of(&aspect));
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        rpass.set_pipeline(&self.pipeline);
        rpass.set_bind_group(0, &self.bind_group, &[]);

        // Reference first (under the trace): the diamond, then the center line.
        rpass.set_vertex_buffer(0, self.frame_buf.slice(..));
        rpass.draw(0..self.frame_diamond_verts, 0..1);
        rpass.draw(self.frame_diamond_verts..self.frame_total_verts, 0..1);

        // The Lissajous trace over it.
        rpass.set_vertex_buffer(0, self.signal_buf.slice(..));
        rpass.draw(0..POINTS as u32, 0..1);
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

struct VOut {
    @builtin(position) position: vec4<f32>,
    @location(0) color: vec4<f32>,
};

@vertex
fn vs_main(@location(0) p: vec2<f32>, @location(1) color: vec4<f32>) -> VOut {
    var o: VOut;
    o.position = vec4<f32>(p.x * a.sx, p.y * a.sy, 0.0, 1.0);
    o.color = color;
    return o;
}

@fragment
fn fs_main(in: VOut) -> @location(0) vec4<f32> {
    return in.color;
}
"#;
