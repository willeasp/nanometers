//! Oscilloscope Module — the instantaneous stereo wave *shape* over a short real-time window
//! (CONTEXT.md). This is the renderer nanometers shipped before the Module host: a line strip per
//! channel, a vertex shader mapping (index, sample) → clip space, stacked into a soft additive
//! "glow". Moved here verbatim and wrapped as the first `Module`.
//!
//! Per ADR 0007 the fake glow is slated for deletion once the real scrolling Waveform Module lands;
//! the default layout will be Waveform + Loudness. The Oscilloscope stays as a real Module.
//!
//! Phase A note: this draws full-surface clip space (identity viewport). The viewport transform
//! ([`Rect::clip_transform`]) that makes it column-local arrives with the layout strip (Phase B).

use std::borrow::Cow;

use bytemuck::{Pod, Zeroable};
use wgpu::util::DeviceExt;

use super::{EventStatus, FrameContext, Module, Rect};
use crate::StereoFrame;

/// How many recent stereo frames the Oscilloscope keeps. 4096 ≈ 85 ms at 48 kHz / 21 ms at
/// 192 kHz — enough to see musical features at any rate.
const DISPLAY_BUFFER_LEN: usize = 4096;

/// Stacked passes for the additive-glow render. Must be odd so there's a central (zero-offset)
/// layer. 9 gives a comfortably soft halo without too many instances per draw.
const GLOW_LAYERS: u32 = 9;

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
struct WaveformUniforms {
    sample_count: u32,
    _pad0: u32,
    y_offset: f32,
    y_scale: f32,
}

pub struct OscilloscopeModule {
    pipeline: wgpu::RenderPipeline,

    // One uniform + bind group per channel, written once at construction with the channel's static
    // y_offset/y_scale. A previous version reused one buffer and rewrote it between the L and R
    // draws — but `queue.write_buffer` is ordered against the next submit, not against individual
    // encoded draws, so both writes happened first and the second won (both lines drew at R).
    bind_group_l: wgpu::BindGroup,
    bind_group_r: wgpu::BindGroup,

    vertex_buffer_l: wgpu::Buffer,
    vertex_buffer_r: wgpu::Buffer,
    vertex_count: u32,

    // Ingest, moved out of the old `RenderWindow` into the Module: most recent DISPLAY_BUFFER_LEN
    // stereo frames as a ring, rotated into contiguous time order for the vertex upload.
    display_buffer: Box<[StereoFrame; DISPLAY_BUFFER_LEN]>,
    write_head: usize,
    linear_scratch_l: Box<[f32; DISPLAY_BUFFER_LEN]>,
    linear_scratch_r: Box<[f32; DISPLAY_BUFFER_LEN]>,
}

impl OscilloscopeModule {
    pub fn new(device: &wgpu::Device, surface_format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("oscilloscope-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(WAVEFORM_WGSL)),
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("oscilloscope-bgl"),
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

        let make_uniform = |label: &str, y_offset: f32| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some(label),
                contents: bytemuck::bytes_of(&WaveformUniforms {
                    sample_count: DISPLAY_BUFFER_LEN as u32,
                    _pad0: 0,
                    y_offset,
                    y_scale: 0.4,
                }),
                usage: wgpu::BufferUsages::UNIFORM,
            })
        };
        let uniform_buffer_l = make_uniform("oscilloscope-uniforms-L", 0.5);
        let uniform_buffer_r = make_uniform("oscilloscope-uniforms-R", -0.5);

        let make_bg = |label: &str, buf: &wgpu::Buffer| {
            device.create_bind_group(&wgpu::BindGroupDescriptor {
                label: Some(label),
                layout: &bind_group_layout,
                entries: &[wgpu::BindGroupEntry {
                    binding: 0,
                    resource: buf.as_entire_binding(),
                }],
            })
        };
        let bind_group_l = make_bg("oscilloscope-bg-L", &uniform_buffer_l);
        let bind_group_r = make_bg("oscilloscope-bg-R", &uniform_buffer_r);

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("oscilloscope-pl"),
            bind_group_layouts: &[Some(&bind_group_layout)],
            immediate_size: 0,
        });

        let vertex_layout = wgpu::VertexBufferLayout {
            array_stride: std::mem::size_of::<f32>() as u64,
            step_mode: wgpu::VertexStepMode::Vertex,
            attributes: &[wgpu::VertexAttribute {
                shader_location: 0,
                format: wgpu::VertexFormat::Float32,
                offset: 0,
            }],
        };

        let pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("oscilloscope-pipeline"),
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
                    format: surface_format,
                    // Additive blending so stacked glow layers sum brightness into a saturated
                    // core. (src.rgb * src.a) + (dst.rgb * 1.0).
                    blend: Some(wgpu::BlendState {
                        color: wgpu::BlendComponent {
                            src_factor: wgpu::BlendFactor::SrcAlpha,
                            dst_factor: wgpu::BlendFactor::One,
                            operation: wgpu::BlendOperation::Add,
                        },
                        alpha: wgpu::BlendComponent {
                            src_factor: wgpu::BlendFactor::One,
                            dst_factor: wgpu::BlendFactor::One,
                            operation: wgpu::BlendOperation::Add,
                        },
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

        let vbuf_size = (DISPLAY_BUFFER_LEN * std::mem::size_of::<f32>()) as u64;
        let make_vbuf = |label: &str| {
            device.create_buffer_init(&wgpu::util::BufferInitDescriptor {
                label: Some(label),
                contents: &vec![0u8; vbuf_size as usize],
                usage: wgpu::BufferUsages::VERTEX | wgpu::BufferUsages::COPY_DST,
            })
        };

        Self {
            pipeline,
            bind_group_l,
            bind_group_r,
            vertex_buffer_l: make_vbuf("oscilloscope-vbuf-L"),
            vertex_buffer_r: make_vbuf("oscilloscope-vbuf-R"),
            vertex_count: DISPLAY_BUFFER_LEN as u32,
            display_buffer: Box::new([[0.0; 2]; DISPLAY_BUFFER_LEN]),
            write_head: 0,
            linear_scratch_l: Box::new([0.0; DISPLAY_BUFFER_LEN]),
            linear_scratch_r: Box::new([0.0; DISPLAY_BUFFER_LEN]),
        }
    }

    /// Rotate the ring into the scratch arrays so index 0 is the oldest frame — the vertex buffer
    /// wants contiguous samples in time order to draw one line strip without a seam.
    fn linearize(&mut self) {
        let split = self.write_head;
        let head_to_end = DISPLAY_BUFFER_LEN - split;
        for i in 0..head_to_end {
            let frame = self.display_buffer[split + i];
            self.linear_scratch_l[i] = frame[0];
            self.linear_scratch_r[i] = frame[1];
        }
        for i in 0..split {
            let frame = self.display_buffer[i];
            self.linear_scratch_l[head_to_end + i] = frame[0];
            self.linear_scratch_r[head_to_end + i] = frame[1];
        }
    }
}

impl Module for OscilloscopeModule {
    fn update(&mut self, ctx: &FrameContext, queue: &wgpu::Queue) {
        for &frame in ctx.new {
            self.display_buffer[self.write_head] = frame;
            self.write_head = (self.write_head + 1) % DISPLAY_BUFFER_LEN;
        }
        self.linearize();

        // queue.write_buffer is ordered before this submit, so the uploaded window is visible to
        // both the prepare passes and the shared render pass of this frame.
        queue.write_buffer(
            &self.vertex_buffer_l,
            0,
            bytemuck::cast_slice(self.linear_scratch_l.as_slice()),
        );
        queue.write_buffer(
            &self.vertex_buffer_r,
            0,
            bytemuck::cast_slice(self.linear_scratch_r.as_slice()),
        );
    }

    fn render(&mut self, rpass: &mut wgpu::RenderPass, _viewport: Rect) {
        // Self-contained: set every state this draw depends on; the host guarantees only scissor.
        rpass.set_pipeline(&self.pipeline);

        // L: top half. Each draw is instanced over GLOW_LAYERS — the vertex shader offsets y and
        // modulates alpha per layer for a Gaussian-falloff additive glow.
        rpass.set_bind_group(0, &self.bind_group_l, &[]);
        rpass.set_vertex_buffer(0, self.vertex_buffer_l.slice(..));
        rpass.draw(0..self.vertex_count, 0..GLOW_LAYERS);

        // R: bottom half.
        rpass.set_bind_group(0, &self.bind_group_r, &[]);
        rpass.set_vertex_buffer(0, self.vertex_buffer_r.slice(..));
        rpass.draw(0..self.vertex_count, 0..GLOW_LAYERS);
    }

    fn on_event(&mut self, _event: &baseview::Event, _viewport: Rect) -> EventStatus {
        EventStatus::Ignored
    }

    fn save_config(&self) -> Vec<u8> {
        Vec::new()
    }

    fn load_config(&mut self, _bytes: &[u8]) {}
}

const WAVEFORM_WGSL: &str = r#"
struct Uniforms {
    sample_count: u32,
    _pad0: u32,
    // Clip-space Y center for this channel: +0.5 for L (top half), -0.5 for R (bottom half).
    y_offset: f32,
    // Vertical amplitude scale. With y_offset 0.5 and y_scale 0.4, sample = +1 reaches y = 0.9
    // (near the top edge) and sample = -1 reaches y = 0.1 (near the channel split line).
    y_scale: f32,
};

@group(0) @binding(0) var<uniform> u: Uniforms;

struct VertexOut {
    @builtin(position) position: vec4<f32>,
    @location(0) alpha: f32,
};

@vertex
fn vs_main(
    @location(0) sample: f32,
    @builtin(vertex_index) idx: u32,
    @builtin(instance_index) layer: u32,
) -> VertexOut {
    let half_layers: i32 = 4;
    let off: i32 = i32(layer) - half_layers;

    let layer_spread: f32 = 0.006;
    let y_layer_offset: f32 = f32(off) * layer_spread;

    let denom = max(f32(u.sample_count) - 1.0, 1.0);
    let x = (f32(idx) / denom) * 2.0 - 1.0;
    let y = u.y_offset + clamp(sample, -1.0, 1.0) * u.y_scale + y_layer_offset;

    let weight = exp(-f32(off * off) / 6.0) * 0.4;

    var out: VertexOut;
    out.position = vec4<f32>(x, y, 0.0, 1.0);
    out.alpha = weight;
    return out;
}

@fragment
fn fs_main(in: VertexOut) -> @location(0) vec4<f32> {
    return vec4<f32>(0.55, 0.85, 1.0, in.alpha);
}
"#;
