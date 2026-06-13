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

use crate::layout::{Column, default_layout, reconcile_fixed_widths, remap_to_layout_order, viewports};
use crate::module::loudness::LoudnessModule;
use crate::module::oscilloscope::OscilloscopeModule;
use crate::module::waveform::WaveformModule;
use crate::module::{FrameContext, Module, Rect};
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

/// Main thread → render thread. Resizes coalesce (only the latest size matters); input events must
/// NOT coalesce (every press/move/release counts), so they share one channel and the render loop
/// splits them on drain. `baseview::Event` is plain data (no `Rc`/raw ptr), so it crosses the seam.
enum WindowMsg {
    /// New physical surface size + display scale; the render thread owns the surface and reconfigures.
    /// The scale rides along so px-sized text/padding survives a DPI change.
    Resize { w: u32, h: u32, scale: f32 },
    /// A pointer (or other non-resize) event, forwarded verbatim for the render-side pointer-grab
    /// router (ADR 0004, amended) — modules + layout live render-side, so the router does too.
    Input(baseview::Event),
}

/// The baseview `WindowHandler` — but it does NOT render. Rendering runs on a dedicated thread
/// (`run_render_loop`) paced by the swapchain's blocking acquire, so frame delivery is independent of
/// the host pumping baseview's `on_frame` (FL Studio starves/over-pumps it). This struct only owns
/// the main-thread side: it forwards resize + input events to the render thread. The GPU state,
/// Modules, layout, and per-frame work all live on the render thread (owned by `run_render_loop`).
struct RenderWindow {
    params: Arc<NanometersParams>,
    /// Resize + input → the render thread (see [`WindowMsg`]).
    msg_tx: Sender<WindowMsg>,
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
/// An unknown tag stands in with the Oscilloscope for now; Phase F will make the unknown-tag
/// placeholder preserve the original type + config bytes for lossless re-save.
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

/// Push each column's persisted opaque config (ADR 0003) into its freshly-built Module. Called at
/// editor spawn AFTER `build_module` — modules + layout are 1:1 by position. A module treats
/// unrecognized/empty bytes as defaults, so this is always safe (including the default empty config).
fn load_configs(modules: &mut [Box<dyn Module + Send>], layout: &[Column]) {
    for (m, c) in modules.iter_mut().zip(layout.iter()) {
        m.load_config(&c.config);
    }
}

/// Flush each live Module's config back into its column's opaque bytes. Called after an input batch
/// (the only time config can change), so a host-triggered persist — whenever it lands — sees fresh
/// bytes instead of the stale empty default. Without this, config never round-trips (the F1 bug).
fn flush_configs(modules: &[Box<dyn Module + Send>], layout: &mut [Column]) {
    for (m, c) in modules.iter().zip(layout.iter_mut()) {
        c.config = m.save_config();
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
        pollster::block_on(Self::create(
            target,
            width,
            height,
            params,
            shared,
            render_ctl,
            scaling_factor,
        ))
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
        scale_factor: f32,
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
        let mut layout = params.editor_state.layout_snapshot();
        let mut modules: Vec<Box<dyn Module + Send>> = layout
            .iter()
            .map(|c| build_module(&c.module_type, &device, surface_config.format))
            .collect();
        // Restore each module's persisted per-instance config from its column bytes (ADR 0003).
        // Without this the bytes round-trip through serde but never reach the module — config lost.
        load_configs(&mut modules, &layout);
        // Re-pin intrinsically-sized columns from the LIVE modules — persisted widths can be stale
        // (a layout-knob edit since the save) or missing (legacy flex layouts); the module is the
        // source of truth (ADR 0003, amended). Written back so re-saves carry the corrected widths.
        let intrinsics: Vec<Option<f32>> = modules.iter().map(|m| m.intrinsic_width()).collect();
        reconcile_fixed_widths(&mut layout, &intrinsics);
        params.editor_state.set_layout(layout.clone());

        let (msg_tx, msg_rx) = std::sync::mpsc::channel::<WindowMsg>();
        let render_shared = Arc::clone(&shared);
        let loop_ctl = Arc::clone(&render_ctl);
        // The render-side router commits reorders straight into the persisted layout, so the loop
        // needs the EditorState (it only had `shared` before).
        let render_state = Arc::clone(&params.editor_state);
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
                    render_state,
                    loop_ctl,
                    msg_rx,
                    scale_factor,
                );
            })
            .expect("spawn nanometers render thread");
        *render_ctl.join.lock().unwrap() = Some(handle);

        Self { params, msg_tx }
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
    mut layout: Vec<Column>,
    shared: Arc<Shared>,
    state: Arc<EditorState>,
    ctl: Arc<RenderControl>,
    msg_rx: Receiver<WindowMsg>,
    initial_scale: f32,
) {
    /// Frame-interval clamp handed to Modules: the first iteration and every post-occlusion-sleep
    /// iteration have a large real interval; cap it so a Module integrating `dt` can't lurch.
    const MAX_FRAME_DT: f64 = 0.1;

    // Display backing scale. Seeded from the host/window scale (right for plugins, where no Resized
    // may fire if it already matches the backing) and updated by resize events (the standalone opens
    // claiming 1.0, then a Resized corrects it to the panel's real 2.0 once the backing settles).
    let mut scale_factor = initial_scale;

    let mut new_samples: Vec<StereoFrame> = Vec::with_capacity(4096);
    // Cadence diagnostics now measure the PRESENT interval (this loop presents once per iteration),
    // gated on `NANO_DEBUG_FRAMES` — the true smoothness signal.
    let mut frame_dbg = FrameDebug {
        enabled: crate::diag_enabled("NANO_DEBUG_FRAMES"),
        ..Default::default()
    };
    let mut last = Instant::now();
    // Host-owned pointer-grab state (ADR 0004, amended: render-side). Transient — never persisted.
    let mut router = crate::input::Router::new();

    while !ctl.stop.load(Ordering::Relaxed) {
        // Drain the message channel (host → main thread → here): coalesce resizes (only the latest
        // size matters), buffer input events in order (the router can't miss a press/release). The
        // render thread owns the surface, so resize reconfiguration happens here.
        let mut pending_resize = None;
        let mut inputs: Vec<baseview::Event> = Vec::new();
        while let Ok(msg) = msg_rx.try_recv() {
            match msg {
                WindowMsg::Resize { w, h, scale } => pending_resize = Some((w, h, scale)),
                WindowMsg::Input(ev) => inputs.push(ev),
            }
        }
        if let Some((w, h, scale)) = pending_resize {
            surface_config.width = w.max(1);
            surface_config.height = h.max(1);
            surface.configure(&device, &surface_config);
            scale_factor = scale;
        }
        // Run the pointer-grab router over this batch of input (after the resize, so it hit-tests
        // against the current surface). Hit-testing uses the STABLE committed viewports — the swap
        // points stay put under the cursor even as the strip reflows. A reorder commit returns the
        // new order (modules already permuted to match); adopt + persist it.
        let committed_vps = viewports(
            &layout,
            surface_config.width as f32,
            surface_config.height as f32,
            scale_factor,
        );
        let mut layout_dirty = false;
        for ev in &inputs {
            if let Some(new) = router.handle(ev, &layout, &committed_vps, &mut modules, scale_factor)
            {
                layout = new;
                layout_dirty = true;
            }
        }
        // Persist when something durable changed: a committed reorder, or a discrete press/release/
        // scroll that a module may have turned into a config change (the only way config mutates).
        // Pure cursor-move batches (hover / drag-tracking) publish nothing — no lock on the idle/
        // hover path. The single publish carries both the reorder AND the flushed config (ADR 0003).
        let discrete = inputs.iter().any(|e| {
            matches!(
                e,
                baseview::Event::Mouse(
                    baseview::MouseEvent::ButtonPressed { .. }
                        | baseview::MouseEvent::ButtonReleased { .. }
                        | baseview::MouseEvent::WheelScrolled { .. }
                )
            )
        });
        if layout_dirty || discrete {
            flush_configs(&modules, &mut layout);
            state.set_layout(layout.clone());
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

        // Per-column viewports tiling the surface (ADR 0003), remapped to MODULE order. While a
        // reorder drags, the strip re-tiles from the router's provisional order (live-reflow); the
        // modules Vec stays in committed order, so each module's viewport is looked up by its
        // instance_id. No drag → the active order IS the committed layout, so this is identity.
        let active: &[Column] = router.provisional().unwrap_or(&layout);
        let active_vps = viewports(
            active,
            surface_config.width as f32,
            surface_config.height as f32,
            scale_factor,
        );
        let viewports: Vec<Rect> = remap_to_layout_order(&layout, active, &active_vps);

        // Phase 2a: each Module encodes its own offscreen passes / per-frame uploads before the
        // shared pass opens. `scale_factor` rides along so logical-px sizing lands right on Retina.
        for (m, vp) in modules.iter_mut().zip(viewports.iter()) {
            m.prepare(&device, &queue, &mut encoder, *vp, scale_factor);
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
        match &event {
            baseview::Event::Window(baseview::WindowEvent::Resized(info)) => {
                self.params.editor_state.size.store((
                    info.logical_size().width.round() as u32,
                    info.logical_size().height.round() as u32,
                ));
                // The render thread owns the surface; hand it the new physical size + display scale.
                let _ = self.msg_tx.send(WindowMsg::Resize {
                    w: info.physical_size().width,
                    h: info.physical_size().height,
                    scale: info.scale() as f32,
                });
                baseview::EventStatus::Captured
            }
            // Pass keyboard back to the host: baseview only honors Captured/Ignored for keyboard, and
            // a DAW expects transport shortcuts (spacebar, etc.) to work while our window is focused.
            // We render no param GUI, so we have no keyboard use of our own.
            baseview::Event::Keyboard(_) => baseview::EventStatus::Ignored,
            // Pointer (and the rest): forward to the render-side router (ADR 0004, amended) and
            // capture — these are ours to interpret (reorder, reset, hover).
            _ => {
                let _ = self.msg_tx.send(WindowMsg::Input(event.clone()));
                baseview::EventStatus::Captured
            }
        }
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
            // The shape real persisted state carries since fixed columns landed — the pinned width
            // must survive the round trip too, not just the flex fields.
            Column::fixed(9, module_type::LOUDNESS, 151.0),
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
        assert_eq!(l[1].fixed_width_px, Some(151.0));
    }

    /// A Module with no GPU state — `load_configs`/`flush_configs` only touch save/load_config, never
    /// render, so this is constructible in a unit test (render/update are unreachable no-ops here).
    struct FakeModule {
        config: Vec<u8>,
    }
    impl Module for FakeModule {
        fn update(&mut self, _c: &FrameContext, _q: &wgpu::Queue) {}
        fn render(&mut self, _r: &mut wgpu::RenderPass, _v: Rect) {}
        fn on_event(&mut self, _e: &baseview::Event, _v: Rect) -> crate::module::EventStatus {
            crate::module::EventStatus::Ignored
        }
        fn save_config(&self) -> Vec<u8> {
            self.config.clone()
        }
        fn load_config(&mut self, bytes: &[u8]) {
            self.config = bytes.to_vec();
        }
    }

    #[test]
    fn configs_load_into_modules_then_flush_back_into_columns() {
        let mut layout = vec![
            column_with_config(7, module_type::WAVEFORM, 0.5, b"persisted-A".to_vec()),
            column_with_config(9, module_type::LOUDNESS, 0.5, b"persisted-B".to_vec()),
        ];
        let mut modules: Vec<Box<dyn Module + Send>> = vec![
            Box::new(FakeModule { config: Vec::new() }),
            Box::new(FakeModule { config: Vec::new() }),
        ];
        // LOAD: the persisted bytes reach the modules (1:1 by position).
        load_configs(&mut modules, &layout);
        assert_eq!(modules[0].save_config(), b"persisted-A");
        assert_eq!(modules[1].save_config(), b"persisted-B");
        // A live config change, then FLUSH: the new bytes land back in the columns.
        modules[0].load_config(b"changed-A");
        flush_configs(&modules, &mut layout);
        assert_eq!(layout[0].config, b"changed-A");
        assert_eq!(layout[1].config, b"persisted-B");
    }
}
