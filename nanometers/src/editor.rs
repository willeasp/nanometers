//! Editor + render pipeline. GUI-thread side of nanometers.
//!
//! Owns the baseview window, the wgpu device/surface/pipeline, and the per-frame DSP→GPU
//! upload. The audio thread never touches anything in here.

use baseview::{WindowHandle, WindowOpenOptions, WindowScalePolicy};
use crossbeam::atomic::AtomicCell;
use nih_plug::params::persist::PersistentField;
use nih_plug::prelude::*;
use raw_window_handle::{HasRawWindowHandle, RawWindowHandle};
use serde::{Deserialize, Serialize};
use std::{
    num::{NonZeroIsize, NonZeroU32},
    ptr::NonNull,
    sync::{
        Arc, Mutex,
        atomic::{AtomicBool, Ordering},
    },
};
use wgpu::SurfaceTargetUnsafe;

use crate::layout::{Column, default_layout, viewports};
use crate::module::oscilloscope::OscilloscopeModule;
use crate::module::{FrameContext, Module};
use crate::{NanometersParams, Shared, StereoFrame};

/// Background — near-black with the faintest blue tint. Will become a deliberate palette
/// choice once the visualization style stabilizes. The host owns the clear (it owns the shared
/// pass); Modules draw over it.
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
    /// The persisted Module strip (ADR 0003). GUI-mutated (reorder / resize / per-Module config);
    /// the audio thread never touches it — `process` only reads the disjoint `open` atomic.
    #[serde(with = "serialize_layout")]
    layout: Mutex<Vec<Column>>,
    #[serde(skip)]
    open: AtomicBool,
}

/// serde glue for `Mutex<Vec<Column>>` (serde has no `Mutex` impl): (de)serialize the inner Vec.
mod serialize_layout {
    use super::{Column, Mutex};
    use serde::{Deserialize, Deserializer, Serialize, Serializer};

    pub fn serialize<S: Serializer>(m: &Mutex<Vec<Column>>, s: S) -> Result<S::Ok, S::Error> {
        m.lock().unwrap().serialize(s)
    }
    pub fn deserialize<'de, D: Deserializer<'de>>(d: D) -> Result<Mutex<Vec<Column>>, D::Error> {
        Ok(Mutex::new(Vec::<Column>::deserialize(d)?))
    }
}

impl EditorState {
    pub(crate) fn from_defaults(size: (u32, u32)) -> Arc<Self> {
        Arc::new(Self {
            size: AtomicCell::new(size),
            layout: Mutex::new(default_layout()),
            open: AtomicBool::new(false),
        })
    }

    pub fn size(&self) -> (u32, u32) {
        self.size.load()
    }

    pub fn is_open(&self) -> bool {
        self.open.load(Ordering::Acquire)
    }

    /// A clone of the current layout — the host reads this at spawn to build its Modules.
    pub fn layout_snapshot(&self) -> Vec<Column> {
        self.layout.lock().unwrap().clone()
    }

    /// Replace the layout (GUI-side: after a reorder/resize commit, or on persist load).
    pub fn set_layout(&self, cols: Vec<Column>) {
        *self.layout.lock().unwrap() = cols;
    }
}

impl<'a> PersistentField<'a, EditorState> for Arc<EditorState> {
    fn set(&self, new_value: EditorState) {
        // Copy BOTH persisted fields. A previous version copied only `size`, silently dropping the
        // deserialized layout — every reopen reverted to default and all Module config (which rides
        // the Column.config bytes through this same path) never persisted.
        self.size.store(new_value.size.load());
        *self.layout.lock().unwrap() = new_value.layout.into_inner().unwrap();
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

    /// The hosted Modules, left→right — one per `layout` column, built from the persisted strip.
    modules: Vec<Box<dyn Module>>,

    /// The column geometry/metadata that `modules` mirrors (same length, same order). Drives the
    /// per-column viewports each frame; reorder/resize (Phase E) mutates this and `EditorState`.
    layout: Vec<Column>,

    /// This frame's freshly drained samples, oldest→newest. GUI-thread-only and reused across
    /// frames (cleared each frame), so its growth never touches the audio path.
    new_samples: Vec<StereoFrame>,
}

/// Resolve a layout `module_type` tag to a concrete Module (ADR 0003 build-time resolution).
///
/// Phase B: the real Waveform (Phase C) and Loudness (Phase D) Modules don't exist yet, so every
/// type stands in with the Oscilloscope — enough to verify the strip renders column-local. Those
/// arms get their real constructors in C/D; an unknown tag stays a placeholder (Phase F will make
/// the placeholder preserve the original type + config bytes for lossless re-save).
fn build_module(
    module_type: &str,
    device: &wgpu::Device,
    format: wgpu::TextureFormat,
) -> Box<dyn Module> {
    use crate::layout::module_type as mt;
    match module_type {
        mt::OSCILLOSCOPE | mt::WAVEFORM | mt::LOUDNESS => {
            Box::new(OscilloscopeModule::new(device, format))
        }
        _ => Box::new(OscilloscopeModule::new(device, format)),
    }
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

        // Build the Module strip from the persisted layout (ADR 0003). Order and count mirror the
        // layout, so `modules` and `layout` zip 1:1 with the per-column viewports.
        let layout = params.editor_state.layout_snapshot();
        let modules: Vec<Box<dyn Module>> = layout
            .iter()
            .map(|c| build_module(&c.module_type, &device, surface_config.format))
            .collect();

        Self {
            gui_context,
            params,
            shared,
            device,
            queue,
            surface,
            surface_config,
            modules,
            layout,
            new_samples: Vec::with_capacity(4096),
        }
    }

    fn reconfigure_surface(&mut self) {
        self.surface.configure(&self.device, &self.surface_config);
    }

    /// Drain whatever the audio thread produced since last frame into `new_samples` (cleared
    /// first), oldest→newest. Wait-free pops; stop when the ring is empty. The lock is
    /// uncontended — only this thread ever touches `samples_rx`; the Mutex is there because
    /// rtrb::Consumer is !Sync, not to coordinate threads.
    fn drain_audio(&mut self) {
        self.new_samples.clear();
        let Ok(mut rx) = self.shared.samples_rx.try_lock() else {
            return;
        };
        while let Ok(frame) = rx.pop() {
            self.new_samples.push(frame);
        }
    }
}

impl baseview::WindowHandler for RenderWindow {
    fn on_frame(&mut self, window: &mut baseview::Window) {
        self.drain_audio();

        // Phase 1: fan this frame's samples out to every Module to fold + upload.
        let sample_rate = self.shared.sample_rate.load(Ordering::Relaxed);
        let mono = self.shared.mono.load(Ordering::Relaxed);
        let ctx = FrameContext {
            new: &self.new_samples,
            meas: &self.shared.meas,
            sample_rate,
            mono,
        };
        for m in self.modules.iter_mut() {
            m.update(&ctx, &self.queue);
        }

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

        // Per-column viewports: integer boundaries from the layout fractions, tiling the surface
        // with no gaps/overlaps (ADR 0003). One Rect per Module, in order.
        let surface_w = self.surface_config.width as f32;
        let surface_h = self.surface_config.height as f32;
        let viewports = viewports(&self.layout, surface_w, surface_h);

        // Phase 2a: each Module encodes its own offscreen passes before the shared pass opens.
        for (m, vp) in self.modules.iter_mut().zip(viewports.iter()) {
            m.prepare(&self.device, &self.queue, &mut encoder, *vp);
        }

        // Phase 2b: one shared single-sample pass, cleared once; each Module draws into its column.
        // Per Module the host sets the viewport (affine-maps [-1,1] → the column) AND the scissor
        // (hard-clips), so a Module emits plain [-1,1] geometry and lands column-local. write_buffer
        // uploads from `update` are ordered before this submit, so the draws see them.
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
            for (m, vp) in self.modules.iter_mut().zip(viewports.iter()) {
                rpass.set_viewport(vp.x, vp.y, vp.w, vp.h, 0.0, 1.0);
                rpass.set_scissor_rect(vp.x as u32, vp.y as u32, vp.w as u32, vp.h as u32);
                m.render(&mut rpass, *vp);
            }
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

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::module_type;

    fn column_with_config(id: u64, ty: &str, frac: f32, config: Vec<u8>) -> Column {
        let mut c = Column::new(id, ty, frac);
        c.config = config;
        c
    }

    #[test]
    fn persist_round_trip_preserves_layout_contents() {
        // The real persist path: serialize EditorState to JSON (nih-plug uses serde_json), then on
        // load deserialize and `PersistentField::set` into the live state. The layout's ids,
        // fractions, AND opaque config bytes must survive — not just the window size.
        let original = EditorState::from_defaults((720, 420));
        original.set_layout(vec![
            column_with_config(7, module_type::WAVEFORM, 0.6, vec![9, 8, 7]),
            column_with_config(9, module_type::LOUDNESS, 0.4, vec![]),
        ]);

        let json = serde_json::to_string(&*original).unwrap();
        let deserialized: EditorState = serde_json::from_str(&json).unwrap();

        let live = EditorState::from_defaults((0, 0));
        PersistentField::set(&live, deserialized);

        assert_eq!(live.size(), (720, 420));
        let l = live.layout_snapshot();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].instance_id, 7);
        assert_eq!(l[0].width_fraction, 0.6);
        assert_eq!(l[0].config, vec![9, 8, 7]);
        assert_eq!(l[1].module_type, module_type::LOUDNESS);
    }
}
