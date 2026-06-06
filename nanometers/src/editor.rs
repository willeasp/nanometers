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
        mpsc::{Receiver, Sender},
    },
    thread::JoinHandle,
    time::{Duration, Instant},
};
use wgpu::SurfaceTargetUnsafe;

use crate::layout::{Column, default_layout, viewports};
use crate::module::loudness::LoudnessModule;
use crate::module::oscilloscope::OscilloscopeModule;
use crate::module::waveform::WaveformModule;
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
        // Per-instance render-thread control, created here so it's fresh for every open and shared by
        // exactly this editor's thread (set in the build closure) and its EditorHandle (Drop).
        let render_ctl = Arc::new(RenderControl {
            stop: AtomicBool::new(false),
            join: Mutex::new(None),
        });
        let build_ctl = Arc::clone(&render_ctl);

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
                RenderWindow::new(window, gui_context, params, shared, build_ctl, scaling.unwrap_or(1.0))
            },
        );

        self.params.editor_state.open.store(true, Ordering::Release);
        Box::new(EditorHandle {
            state: Arc::clone(&self.params.editor_state),
            render_ctl,
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
    render_ctl: Arc<RenderControl>,
    window: WindowHandle,
}

// SAFETY: the host gave us the parent window handle and is the only thing that can close
// us from another thread. The contract says that hand-off is sound.
unsafe impl Send for EditorHandle {}

impl Drop for EditorHandle {
    fn drop(&mut self) {
        self.state.open.store(false, Ordering::Release);
        // Stop + join the render thread BEFORE closing the window. The thread owns the wgpu Surface,
        // which references the NSView's CAMetalLayer; `window.close()` releases that view. If the
        // thread outlived the view it would use-after-free on its next acquire — so it goes first.
        // (Promptness is from the post-acquire stop-check in run_render_loop, NOT this store's
        // ordering — `join` provides the happens-before for the surface dropping before view release.)
        self.render_ctl.stop.store(true, Ordering::Release);
        if let Some(handle) = self.render_ctl.join.lock().unwrap().take() {
            let _ = handle.join();
        }
        self.window.close();
    }
}

// ────────────────────────────────────────────────────────────────────────────────────────
// Render window — owns wgpu, the per-frame display buffer, and the waveform renderer.
// ────────────────────────────────────────────────────────────────────────────────────────

/// Lifetime control for ONE editor instance's render thread. Per-instance (held by `EditorHandle` and
/// shared with the thread), NOT per-plugin — so an overlapping reopen / second editor can't un-stop or
/// orphan another instance's thread. `stop` breaks the loop; `join` holds the handle. `EditorHandle`
/// stops + joins this BEFORE `window.close()` releases the NSView the thread's `Surface` references.
struct RenderControl {
    stop: AtomicBool,
    join: Mutex<Option<JoinHandle<()>>>,
}

/// The baseview `WindowHandler` — but it does NOT render. Rendering runs on a dedicated thread
/// (`run_render_loop`) paced by the swapchain's blocking acquire, so frame delivery is independent of
/// the host pumping baseview's `on_frame` (FL Studio starves/over-pumps it). This struct only owns
/// the main-thread side: it forwards resize events to the render thread. The GPU state, Modules, and
/// per-frame work all live on the render thread (owned by `run_render_loop`).
struct RenderWindow {
    params: Arc<NanometersParams>,
    /// Physical surface size → the render thread, which owns the surface and reconfigures it.
    resize_tx: Sender<(u32, u32)>,
}

#[derive(Default)]
struct FrameDebug {
    enabled: bool,
    last: Option<Instant>,
    intervals_ms: Vec<f64>,
}

impl FrameDebug {
    fn tick(&mut self, now: Instant) {
        if !self.enabled {
            return;
        }
        if let Some(prev) = self.last {
            self.intervals_ms.push((now - prev).as_secs_f64() * 1e3);
        }
        self.last = Some(now);
        if self.intervals_ms.len() >= 240 {
            let n = self.intervals_ms.len() as f64;
            let mean = self.intervals_ms.iter().sum::<f64>() / n;
            let min = self.intervals_ms.iter().cloned().fold(f64::INFINITY, f64::min);
            let max = self.intervals_ms.iter().cloned().fold(0.0, f64::max);
            crate::diag_log(&format!(
                "[nano-frames] {n:.0} frames: mean {mean:.2} ms ({:.1} fps), min {min:.2}, max {max:.2}",
                1e3 / mean
            ));
            self.intervals_ms.clear();
        }
    }
}

/// Resolve a layout `module_type` tag to a concrete Module (ADR 0003 build-time resolution).
///
/// Loudness (Phase D) doesn't exist yet, so it (and any unknown tag) stands in with the
/// Oscilloscope. Phase F will make the unknown-tag placeholder preserve the original type + config
/// bytes for lossless re-save.
fn build_module(
    module_type: &str,
    device: &wgpu::Device,
    format: wgpu::TextureFormat,
) -> Box<dyn Module + Send> {
    use crate::layout::module_type as mt;
    match module_type {
        mt::WAVEFORM => Box::new(WaveformModule::new(device, format)),
        mt::LOUDNESS => Box::new(LoudnessModule::new(device, format)),
        mt::OSCILLOSCOPE => Box::new(OscilloscopeModule::new(device, format)),
        _ => Box::new(OscilloscopeModule::new(device, format)),
    }
}

impl RenderWindow {
    fn new(
        window: &mut baseview::Window<'_>,
        gui_context: Arc<dyn GuiContext>,
        params: Arc<NanometersParams>,
        shared: Arc<Shared>,
        render_ctl: Arc<RenderControl>,
        scaling_factor: f32,
    ) -> Self {
        let _ = gui_context; // the render thread doesn't need it (no param GUI yet)
        let target = baseview_window_to_surface_target(window);
        let (width, height) = scaled_size(params.editor_state.size(), scaling_factor);
        pollster::block_on(Self::create(target, width, height, params, shared, render_ctl))
    }

    /// Create the GPU state and hand it to a dedicated RENDER THREAD, then return the lightweight
    /// main-thread handler. The render thread (not baseview's `on_frame`) drives every frame, paced
    /// by the swapchain — so a host that starves/over-pumps the main run loop (FL Studio) can't make
    /// our frame delivery lumpy. The blocking `get_current_texture` is the clock; there is no display
    /// link in our path.
    async fn create(
        target: SurfaceTargetUnsafe,
        width: u32,
        height: u32,
        params: Arc<NanometersParams>,
        shared: Arc<Shared>,
        render_ctl: Arc<RenderControl>,
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

        let mut surface_config = surface.get_default_config(&adapter, width, height).unwrap();
        // Fifo = vsync-locked present (Metal's default isn't guaranteed Fifo; Immediate/Mailbox tear).
        surface_config.present_mode = wgpu::PresentMode::Fifo;
        // maximumDrawableCount = latency + 1 = 3 on Metal. The blocking acquire still paces the loop
        // to vblank (it stalls once all drawables are in flight), but 3 drawables let the CPU and GPU
        // PIPELINE — latency=1 (2 drawables) serializes them and starved us below the refresh rate
        // (~95 fps on a 120 Hz panel → missed vblanks → judder). One extra frame of latency (~8 ms)
        // is invisible on a meter; sustaining the full refresh is what matters.
        surface_config.desired_maximum_frame_latency = 2;
        surface.configure(&device, &surface_config);

        // Build the Module strip from the persisted layout (ADR 0003), 1:1 with the columns.
        let layout = params.editor_state.layout_snapshot();
        let modules: Vec<Box<dyn Module + Send>> = layout
            .iter()
            .map(|c| build_module(&c.module_type, &device, surface_config.format))
            .collect();

        let (resize_tx, resize_rx) = std::sync::mpsc::channel::<(u32, u32)>();
        let render_shared = Arc::clone(&shared);
        let loop_ctl = Arc::clone(&render_ctl);
        let handle = std::thread::Builder::new()
            .name("nanometers-render".into())
            .spawn(move || {
                run_render_loop(
                    device,
                    queue,
                    surface,
                    surface_config,
                    modules,
                    layout,
                    render_shared,
                    loop_ctl,
                    resize_rx,
                );
            })
            .expect("spawn nanometers render thread");
        *render_ctl.join.lock().unwrap() = Some(handle);

        Self { params, resize_tx }
    }
}

/// The dedicated render thread: `drain → update → acquire → render → present`, forever, until
/// `shared.render_stop`. The `get_current_texture` acquire BLOCKS to vblank (Fifo + 2 drawables),
/// so the loop is self-pacing — no display link, no main-thread dependency. Owns all the GPU state
/// and the Modules; the main thread only feeds it resizes via `resize_rx`.
#[allow(clippy::too_many_arguments)]
fn run_render_loop(
    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    mut surface_config: wgpu::SurfaceConfiguration,
    mut modules: Vec<Box<dyn Module + Send>>,
    layout: Vec<Column>,
    shared: Arc<Shared>,
    ctl: Arc<RenderControl>,
    resize_rx: Receiver<(u32, u32)>,
) {
    /// Frame-interval clamp handed to Modules: the first iteration and every post-occlusion-sleep
    /// iteration have a large real interval; cap it so a Module integrating `dt` can't lurch.
    const MAX_FRAME_DT: f64 = 0.1;

    let mut new_samples: Vec<StereoFrame> = Vec::with_capacity(4096);
    // Cadence diagnostics now measure the PRESENT interval (this loop presents once per iteration),
    // gated on `NANO_DEBUG_FRAMES` — the true smoothness signal.
    let mut frame_dbg = FrameDebug {
        enabled: crate::diag_enabled("NANO_DEBUG_FRAMES"),
        ..Default::default()
    };
    let mut last = Instant::now();

    while !ctl.stop.load(Ordering::Relaxed) {
        // Apply the latest pending resize (host → main thread → here); the render thread owns the
        // surface, so reconfiguration must happen here.
        let mut new_size = None;
        while let Ok(sz) = resize_rx.try_recv() {
            new_size = Some(sz);
        }
        if let Some((w, h)) = new_size {
            surface_config.width = w.max(1);
            surface_config.height = h.max(1);
            surface.configure(&device, &surface_config);
        }

        let now = Instant::now();
        let frame_dt = (now - last).as_secs_f64().min(MAX_FRAME_DT);
        last = now;
        frame_dbg.tick(now);

        // Drain audio (sole consumer; the Mutex only exists because rtrb::Consumer is !Sync). Recover
        // a poisoned lock — a Module panic must not silently kill the meter for the rest of the session.
        new_samples.clear();
        match shared.samples_rx.try_lock() {
            Ok(mut rx) => {
                while let Ok(frame) = rx.pop() {
                    new_samples.push(frame);
                }
            }
            Err(std::sync::TryLockError::Poisoned(p)) => {
                let mut rx = p.into_inner();
                while let Ok(frame) = rx.pop() {
                    new_samples.push(frame);
                }
            }
            Err(std::sync::TryLockError::WouldBlock) => {}
        }

        // Phase 1: fan this frame's samples out to every Module. The loop is itself vsync-paced, so
        // frame_dt is the steady per-frame interval.
        let sample_rate = shared.sample_rate.load(Ordering::Relaxed);
        let mono = shared.mono.load(Ordering::Relaxed);
        let ctx = FrameContext {
            new: &new_samples,
            meas: &shared.meas,
            sample_rate,
            mono,
            frame_dt,
        };
        for m in modules.iter_mut() {
            m.update(&ctx, &queue);
        }

        // Acquire — BLOCKS until a drawable frees at vblank. This is the pacing clock.
        let frame = match surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture) => texture,
            // Hidden/occluded/stalled: don't busy-spin — wait roughly a frame and retry.
            wgpu::CurrentSurfaceTexture::Occluded
            | wgpu::CurrentSurfaceTexture::Timeout
            | wgpu::CurrentSurfaceTexture::Validation => {
                std::thread::sleep(Duration::from_millis(16));
                continue;
            }
            // Stale/lost config: reconfigure, then sleep so a wedged surface can't busy-spin a core.
            wgpu::CurrentSurfaceTexture::Suboptimal(_)
            | wgpu::CurrentSurfaceTexture::Outdated
            | wgpu::CurrentSurfaceTexture::Lost => {
                surface.configure(&device, &surface_config);
                std::thread::sleep(Duration::from_millis(16));
                continue;
            }
        };

        // The acquire above can block for a full frame; check the stop flag the moment it returns so
        // teardown (EditorHandle::drop → join) waits at most one frame, not the NEXT blocking acquire.
        // The acquired drawable just drops unpresented, which releases it.
        if ctl.stop.load(Ordering::Relaxed) {
            break;
        }

        let view = frame
            .texture
            .create_view(&wgpu::TextureViewDescriptor::default());
        let mut encoder = device.create_command_encoder(&wgpu::CommandEncoderDescriptor {
            label: Some("nanometers-encoder"),
        });

        // Per-column viewports tiling the surface (ADR 0003), one Rect per Module in order.
        let viewports = viewports(
            &layout,
            surface_config.width as f32,
            surface_config.height as f32,
        );

        // Phase 2a: each Module encodes its own offscreen passes before the shared pass opens.
        for (m, vp) in modules.iter_mut().zip(viewports.iter()) {
            m.prepare(&device, &queue, &mut encoder, *vp);
        }

        // Phase 2b: one shared single-sample pass; each Module draws into its column (host sets the
        // viewport + scissor, so a Module emits plain [-1,1] geometry and lands column-local).
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
            for (m, vp) in modules.iter_mut().zip(viewports.iter()) {
                rpass.set_viewport(vp.x, vp.y, vp.w, vp.h, 0.0, 1.0);
                rpass.set_scissor_rect(vp.x as u32, vp.y as u32, vp.w as u32, vp.h as u32);
                m.render(&mut rpass, *vp);
            }
        }

        queue.submit(Some(encoder.finish()));
        // Async present (CAMetalLayer.presentsWithTransaction defaults false, wgpu doesn't override),
        // so the finished frame is handed to the render server WITHOUT waiting on the host's CATransaction.
        frame.present();
    }
}

impl baseview::WindowHandler for RenderWindow {
    /// Intentionally empty. Rendering is driven by the dedicated render thread (`run_render_loop`),
    /// not by this callback — that's the whole point: a host pumping `on_frame` erratically (FL) no
    /// longer dictates our frame cadence. baseview still calls this at the host's whim; we ignore it.
    fn on_frame(&mut self, _window: &mut baseview::Window) {}

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
            // The render thread owns the surface; hand it the new physical size to reconfigure.
            let _ = self
                .resize_tx
                .send((info.physical_size().width, info.physical_size().height));
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
