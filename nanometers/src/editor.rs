//! Editor + render pipeline. GUI-thread side of nanometers.
//!
//! Owns the baseview window, the wgpu device/surface/pipeline, and the per-frame DSP→GPU
//! upload. The audio thread never touches anything in here.

use baseview::{WindowHandle, WindowOpenOptions, WindowScalePolicy};
use bytemuck::{Pod, Zeroable};
use crossbeam::atomic::AtomicCell;
use nih_plug::params::persist::PersistentField;
use nih_plug::prelude::*;
use raw_window_handle::{HasRawWindowHandle, RawWindowHandle};
use serde::{Deserialize, Serialize};
use std::{
    borrow::Cow,
    num::{NonZeroIsize, NonZeroU32},
    ptr::NonNull,
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use wgpu::{SurfaceTargetUnsafe, util::DeviceExt};

use crate::{NanometersParams, Shared, StereoFrame};

/// How many recent stereo frames the GUI keeps for the waveform display.
/// 4096 ≈ 85 ms at 48 kHz / 21 ms at 192 kHz. Enough to see musical features at any rate.
const DISPLAY_BUFFER_LEN: usize = 4096;

/// Background — near-black with the faintest blue tint. Will become a deliberate palette
/// choice once the visualization style stabilizes.
const CLEAR_COLOR: wgpu::Color = wgpu::Color {
    r: 0.014,
    g: 0.016,
    b: 0.022,
    a: 1.0,
};

// ────────────────────────────────────────────────────────────────────────────────────────
// Editor state — persisted with the host project so window size survives reopens.
// ────────────────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct EditorState {
    #[serde(with = "nih_plug::params::persist::serialize_atomic_cell")]
    size: AtomicCell<(u32, u32)>,
    #[serde(skip)]
    open: AtomicBool,
}

impl EditorState {
    pub(crate) fn from_size(size: (u32, u32)) -> Arc<Self> {
        Arc::new(Self {
            size: AtomicCell::new(size),
            open: AtomicBool::new(false),
        })
    }

    pub fn size(&self) -> (u32, u32) {
        self.size.load()
    }

    pub fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire)
    }
}

impl<'a> PersistentField<'a, EditorState> for Arc<EditorState> {
    fn set(&self, new_value: EditorState) {
        self.size.store(new_value.size.load());
    }
    fn map<F, R>(&self, f: F) -> R
    where
        F: Fn(&EditorState) -> R,
    {
        f(self)
    }
}

// ────────────────────────────────────────────────────────────────────────────────────────
// Editor — talks to the host, spawns the baseview window.
// ────────────────────────────────────────────────────────────────────────────────────────

pub struct NanometersEditor {
    pub params: Arc<NanometersParams>,
    pub shared: Arc<Shared>,
    pub scaling_factor: AtomicCell<Option<f32>>,
}

impl Editor for NanometersEditor {
    fn spawn(
        &self,
        parent: ParentWindowHandle,
        context: Arc<dyn GuiContext>,
    ) -> Box<dyn std::any::Any + Send> {
        let (unscaled_w, unscaled_h) = self.params.editor_state.size();
        let scaling = self.scaling_factor.load();

        let gui_context = Arc::clone(&context);
        let params = Arc::clone(&self.params);
        let shared = Arc::clone(&self.shared);

        let window = baseview::Window::open_parented(
            &ParentWindowHandleAdapter(parent),
            WindowOpenOptions {
                title: String::from("nanometers"),
                size: baseview::Size::new(unscaled_w as f64, unscaled_h as f64),
                scale: scaling
                    .map(|f| WindowScalePolicy::ScaleFactor(f as f64))
                    .unwrap_or(WindowScalePolicy::SystemScaleFactor),
                ..Default::default()
            },
            move |window: &mut baseview::Window<'_>| -> RenderWindow {
                RenderWindow::new(window, gui_context, params, shared, scaling.unwrap_or(1.0))
            },
        );

        self.params.editor_state.open.store(true, Ordering::Release);
        Box::new(EditorHandle {
            state: Arc::clone(&self.params.editor_state),
            window,
        })
    }

    fn size(&self) -> (u32, u32) {
        self.params.editor_state.size()
    }

    fn set_scale_factor(&self, factor: f32) -> bool {
        if self.params.editor_state.is_open() {
            return false;
        }
        self.scaling_factor.store(Some(factor));
        true
    }

    fn param_value_changed(&self, _id: &str, _normalized_value: f32) {}
    fn param_modulation_changed(&self, _id: &str, _modulation_offset: f32) {}
    fn param_values_changed(&self) {}
}

struct EditorHandle {
    state: Arc<EditorState>,
    window: WindowHandle,
}

// SAFETY: the host gave us the parent window handle and is the only thing that can close
// us from another thread. The contract says that hand-off is sound.
unsafe impl Send for EditorHandle {}

impl Drop for EditorHandle {
    fn drop(&mut self) {
        self.state.open.store(false, Ordering::Release);
        self.window.close();
    }
}

// ────────────────────────────────────────────────────────────────────────────────────────
// Render window — owns wgpu, the per-frame display buffer, and the waveform renderer.
// ────────────────────────────────────────────────────────────────────────────────────────

struct RenderWindow {
    #[allow(dead_code)]
    gui_context: Arc<dyn GuiContext>,
    params: Arc<NanometersParams>,
    shared: Arc<Shared>,

    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    surface_config: wgpu::SurfaceConfiguration,

    waveform: WaveformRenderer,

    /// Most recent `DISPLAY_BUFFER_LEN` stereo frames, ordered oldest→newest after `to_linear`.
    /// Ring with `write_head` lets us avoid shifting on every push.
    display_buffer: Box<[StereoFrame; DISPLAY_BUFFER_LEN]>,
    write_head: usize,

    /// Scratch space copied into for the GPU upload each frame (rotated so the oldest sample
    /// is at index 0). Reused to avoid per-frame allocation.
    linear_scratch_l: Box<[f32; DISPLAY_BUFFER_LEN]>,
    linear_scratch_r: Box<[f32; DISPLAY_BUFFER_LEN]>,
}

impl RenderWindow {
    fn new(
        window: &mut baseview::Window<'_>,
        gui_context: Arc<dyn GuiContext>,
        params: Arc<NanometersParams>,
        shared: Arc<Shared>,
        scaling_factor: f32,
    ) -> Self {
        let target = baseview_window_to_surface_target(window);
        let (width, height) = scaled_size(params.editor_state.size(), scaling_factor);

        pollster::block_on(Self::create(
            target,
            width,
            height,
            gui_context,
            params,
            shared,
        ))
    }

    async fn create(
        target: SurfaceTargetUnsafe,
        width: u32,
        height: u32,
        gui_context: Arc<dyn GuiContext>,
        params: Arc<NanometersParams>,
        shared: Arc<Shared>,
    ) -> Self {
        let instance = wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
        let surface = unsafe { instance.create_surface_unsafe(target) }.unwrap();

        let adapter = instance
            .request_adapter(&wgpu::RequestAdapterOptions {
                power_preference: wgpu::PowerPreference::LowPower,
                force_fallback_adapter: false,
                compatible_surface: Some(&surface),
            })
            .await
            .expect("Failed to find a wgpu adapter");

        let (device, queue) = adapter
            .request_device(&wgpu::DeviceDescriptor {
                label: Some("nanometers-device"),
                required_features: wgpu::Features::empty(),
                required_limits: wgpu::Limits::downlevel_webgl2_defaults()
                    .using_resolution(adapter.limits()),
                memory_hints: wgpu::MemoryHints::MemoryUsage,
                ..Default::default()
            })
            .await
            .expect("Failed to create wgpu device");

        let surface_config = surface.get_default_config(&adapter, width, height).unwrap();
        surface.configure(&device, &surface_config);

        let waveform = WaveformRenderer::new(&device, surface_config.format);

        Self {
            gui_context,
            params,
            shared,
            device,
            queue,
            surface,
            surface_config,
            waveform,
            display_buffer: Box::new([[0.0; 2]; DISPLAY_BUFFER_LEN]),
            write_head: 0,
            linear_scratch_l: Box::new([0.0; DISPLAY_BUFFER_LEN]),
            linear_scratch_r: Box::new([0.0; DISPLAY_BUFFER_LEN]),
        }
    }

    fn reconfigure_surface(&mut self) {
        self.surface.configure(&self.device, &self.surface_config);
    }

    /// Drain whatever the audio thread has produced since last frame into our ring.
    /// Wait-free pops; we stop when the ring is empty.
    fn drain_audio(&mut self) {
        // The lock is uncontended — only this thread ever touches `samples_rx`. The Mutex is
        // there for type-system reasons (rtrb::Consumer is !Sync), not to coordinate threads.
        let Ok(mut rx) = self.shared.samples_rx.try_lock() else {
            return;
        };
        while let Ok(frame) = rx.pop() {
            self.display_buffer[self.write_head] = frame;
            self.write_head = (self.write_head + 1) % DISPLAY_BUFFER_LEN;
        }
    }

    /// Rotate the ring into the scratch arrays so index 0 is the oldest frame. The wgpu
    /// vertex buffer wants contiguous samples in time order to render a single line strip
    /// without an ugly seam.
    fn linearize_for_render(&mut self) {
        let split = self.write_head;
        // First chunk: from write_head to end = oldest samples
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

impl baseview::WindowHandler for RenderWindow {
    fn on_frame(&mut self, window: &mut baseview::Window) {
        self.drain_audio();
        self.linearize_for_render();

        let mut recreate_surface = false;
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture) => Some(texture),
            // Window not visible or compositor stalled — skip this frame.
            wgpu::CurrentSurfaceTexture::Occluded
            | wgpu::CurrentSurfaceTexture::Timeout
            | wgpu::CurrentSurfaceTexture::Validation => return,
            // Reconfigure the surface and skip; we'll catch up next frame.
            wgpu::CurrentSurfaceTexture::Suboptimal(_) | wgpu::CurrentSurfaceTexture::Outdated => {
                None
            }
            // Device-lost / context dropped — rebuild the surface from the window handle.
            wgpu::CurrentSurfaceTexture::Lost => {
                recreate_surface = true;
                None
            }
        };

        let Some(frame) = frame else {
            if recreate_surface {
                let target = baseview_window_to_surface_target(window);
                let instance =
                    wgpu::Instance::new(wgpu::InstanceDescriptor::new_without_display_handle());
                self.surface = unsafe { instance.create_surface_unsafe(target) }.unwrap();
            }
            self.reconfigure_surface();
            return;
        };

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = self
            .device
            .create_command_encoder(&wgpu::CommandEncoderDescriptor {
                label: Some("nanometers-encoder"),
            });

        // Upload current sample window. queue.write_buffer is scheduled before the submit,
        // so it must happen before begin_render_pass for the encoded draws to see it.
        self.queue.write_buffer(
            &self.waveform.vertex_buffer_l,
            0,
            bytemuck::cast_slice(self.linear_scratch_l.as_slice()),
        );
        self.queue.write_buffer(
            &self.waveform.vertex_buffer_r,
            0,
            bytemuck::cast_slice(self.linear_scratch_r.as_slice()),
        );

        {
            let mut rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("nanometers-frame"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        load: wgpu::LoadOp::Clear(CLEAR_COLOR),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
            self.waveform.render(&mut rpass, &self.queue);
        }

        self.queue.submit(Some(encoder.finish()));
        frame.present();
    }

    fn on_event(
        &mut self,
        _window: &mut baseview::Window,
        event: baseview::Event,
    ) -> baseview::EventStatus {
        if let baseview::Event::Window(baseview::WindowEvent::Resized(info)) = &event {
            self.params.editor_state.size.store((
                info.logical_size().width.round() as u32,
                info.logical_size().height.round() as u32,
            ));
            self.surface_config.width = info.physical_size().width;
            self.surface_config.height = info.physical_size().height;
            self.reconfigure_surface();
        }
        baseview::EventStatus::Captured
    }
}

fn scaled_size((w, h): (u32, u32), scale: f32) -> (u32, u32) {
    (
        (w as f64 * scale as f64).round() as u32,
        (h as f64 * scale as f64).round() as u32,
    )
}

// ────────────────────────────────────────────────────────────────────────────────────────
// Waveform renderer — line strip per channel, vertex shader maps (index, sample) → clip.
// One pipeline, two draws, one uniform buffer rewritten between them for y_offset.
// ────────────────────────────────────────────────────────────────────────────────────────

#[repr(C)]
#[derive(Copy, Clone, Debug, Pod, Zeroable)]
struct WaveformUniforms {
    sample_count: u32,
    _pad0: u32,
    y_offset: f32,
    y_scale: f32,
}

struct WaveformRenderer {
    pipeline: wgpu::RenderPipeline,

    // One uniform + bind group per channel. They're written once at construction with the
    // channel's static y_offset/y_scale, never touched afterwards. A previous version reused
    // one buffer and rewrote it between draws — but `queue.write_buffer` is ordered against
    // the next submit, not against individual encoded draws, so both writes happened first
    // and the second one won. Resulted in both lines drawing at the R position.
    bind_group_l: wgpu::BindGroup,
    bind_group_r: wgpu::BindGroup,

    vertex_buffer_l: wgpu::Buffer,
    vertex_buffer_r: wgpu::Buffer,
    vertex_count: u32,
}

impl WaveformRenderer {
    fn new(device: &wgpu::Device, surface_format: wgpu::TextureFormat) -> Self {
        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("waveform-shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(WAVEFORM_WGSL)),
        });

        let bind_group_layout = device.create_bind_group_layout(&wgpu::BindGroupLayoutDescriptor {
            label: Some("waveform-bgl"),
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

        // One uniform per channel, written once with bytemuck. We use `create_buffer_init`
        // so the data lands at creation — no separate write_buffer that races with the submit.
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
        let uniform_buffer_l = make_uniform("waveform-uniforms-L", 0.5);
        let uniform_buffer_r = make_uniform("waveform-uniforms-R", -0.5);

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
        let bind_group_l = make_bg("waveform-bg-L", &uniform_buffer_l);
        let bind_group_r = make_bg("waveform-bg-R", &uniform_buffer_r);

        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("waveform-pl"),
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
            label: Some("waveform-pipeline"),
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
                    blend: Some(wgpu::BlendState::ALPHA_BLENDING),
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
            vertex_buffer_l: make_vbuf("waveform-vbuf-L"),
            vertex_buffer_r: make_vbuf("waveform-vbuf-R"),
            vertex_count: DISPLAY_BUFFER_LEN as u32,
        }
    }

    fn render(&self, rpass: &mut wgpu::RenderPass<'_>, _queue: &wgpu::Queue) {
        rpass.set_pipeline(&self.pipeline);

        // L: top half. Uniform was baked in at creation, no per-frame writes needed.
        rpass.set_bind_group(0, &self.bind_group_l, &[]);
        rpass.set_vertex_buffer(0, self.vertex_buffer_l.slice(..));
        rpass.draw(0..self.vertex_count, 0..1);

        // R: bottom half.
        rpass.set_bind_group(0, &self.bind_group_r, &[]);
        rpass.set_vertex_buffer(0, self.vertex_buffer_r.slice(..));
        rpass.draw(0..self.vertex_count, 0..1);
    }
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

@vertex
fn vs_main(
    @location(0) sample: f32,
    @builtin(vertex_index) idx: u32,
) -> @builtin(position) vec4<f32> {
    let denom = max(f32(u.sample_count) - 1.0, 1.0);
    let x = (f32(idx) / denom) * 2.0 - 1.0;
    let y = u.y_offset + clamp(sample, -1.0, 1.0) * u.y_scale;
    return vec4<f32>(x, y, 0.0, 1.0);
}

@fragment
fn fs_main() -> @location(0) vec4<f32> {
    // Soft cyan against a near-black background. Glow comes later (multi-pass blur).
    return vec4<f32>(0.55, 0.85, 1.0, 1.0);
}
"#;

// ────────────────────────────────────────────────────────────────────────────────────────
// raw-window-handle 0.5 ↔ 0.6 plumbing. baseview is on rwh 0.5, wgpu 29 wants 0.6.
// Copied verbatim from nih-plug's byo_gui_wgpu example.
// ────────────────────────────────────────────────────────────────────────────────────────

struct ParentWindowHandleAdapter(nih_plug::editor::ParentWindowHandle);

unsafe impl HasRawWindowHandle for ParentWindowHandleAdapter {
    fn raw_window_handle(&self) -> RawWindowHandle {
        match self.0 {
            ParentWindowHandle::X11Window(window) => {
                let mut handle = raw_window_handle::XcbWindowHandle::empty();
                handle.window = window;
                RawWindowHandle::Xcb(handle)
            }
            ParentWindowHandle::AppKitNsView(ns_view) => {
                let mut handle = raw_window_handle::AppKitWindowHandle::empty();
                handle.ns_view = ns_view;
                RawWindowHandle::AppKit(handle)
            }
            ParentWindowHandle::Win32Hwnd(hwnd) => {
                let mut handle = raw_window_handle::Win32WindowHandle::empty();
                handle.hwnd = hwnd;
                RawWindowHandle::Win32(handle)
            }
        }
    }
}

fn baseview_window_to_surface_target(window: &baseview::Window<'_>) -> wgpu::SurfaceTargetUnsafe {
    use raw_window_handle::{HasRawDisplayHandle, HasRawWindowHandle};

    let raw_display_handle = window.raw_display_handle();
    let raw_window_handle = window.raw_window_handle();

    wgpu::SurfaceTargetUnsafe::RawHandle {
        raw_display_handle: match raw_display_handle {
            raw_window_handle::RawDisplayHandle::AppKit(_) => {
                Some(raw_window_handle_06::RawDisplayHandle::AppKit(
                    raw_window_handle_06::AppKitDisplayHandle::new(),
                ))
            }
            raw_window_handle::RawDisplayHandle::Xlib(handle) => {
                Some(raw_window_handle_06::RawDisplayHandle::Xlib(
                    raw_window_handle_06::XlibDisplayHandle::new(
                        NonNull::new(handle.display),
                        handle.screen,
                    ),
                ))
            }
            raw_window_handle::RawDisplayHandle::Xcb(handle) => {
                Some(raw_window_handle_06::RawDisplayHandle::Xcb(
                    raw_window_handle_06::XcbDisplayHandle::new(
                        NonNull::new(handle.connection),
                        handle.screen,
                    ),
                ))
            }
            raw_window_handle::RawDisplayHandle::Windows(_) => {
                Some(raw_window_handle_06::RawDisplayHandle::Windows(
                    raw_window_handle_06::WindowsDisplayHandle::new(),
                ))
            }
            _ => todo!(),
        },
        raw_window_handle: match raw_window_handle {
            raw_window_handle::RawWindowHandle::AppKit(handle) => {
                raw_window_handle_06::RawWindowHandle::AppKit(
                    raw_window_handle_06::AppKitWindowHandle::new(
                        NonNull::new(handle.ns_view).unwrap(),
                    ),
                )
            }
            raw_window_handle::RawWindowHandle::Xlib(handle) => {
                raw_window_handle_06::RawWindowHandle::Xlib(
                    raw_window_handle_06::XlibWindowHandle::new(handle.window),
                )
            }
            raw_window_handle::RawWindowHandle::Xcb(handle) => {
                raw_window_handle_06::RawWindowHandle::Xcb(
                    raw_window_handle_06::XcbWindowHandle::new(
                        NonZeroU32::new(handle.window).unwrap(),
                    ),
                )
            }
            raw_window_handle::RawWindowHandle::Win32(handle) => {
                let mut raw_handle = raw_window_handle_06::Win32WindowHandle::new(
                    NonZeroIsize::new(handle.hwnd as isize).unwrap(),
                );
                raw_handle.hinstance = NonZeroIsize::new(handle.hinstance as isize);
                raw_window_handle_06::RawWindowHandle::Win32(raw_handle)
            }
            _ => todo!(),
        },
    }
}
