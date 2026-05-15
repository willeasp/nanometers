//! nanometers — chill open-source audio meter plugin.
//!
//! v0.0.1 chassis: load in the host, open a wgpu-rendered window with a dark clear-color,
//! compute stereo peak with decay on the audio thread, expose via an Arc-of-atomics for the
//! GUI to read. No visualization yet — that's the next milestone.

use atomic_float::AtomicF32;
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
        Arc,
        atomic::{AtomicBool, Ordering},
    },
};
use wgpu::SurfaceTargetUnsafe;

const INITIAL_WIDTH: u32 = 720;
const INITIAL_HEIGHT: u32 = 420;

/// Time in ms for the peak meter to drop 12 dB (factor 0.25) after going silent.
const PEAK_DECAY_MS: f64 = 250.0;

/// State shared between the audio thread (writer) and the GUI thread (reader).
/// Single-block-granularity atomics — fine for peak/RMS scalars. Audio-rate sample streams
/// (for waveform/FFT) will get a separate rtrb ring buffer when we add those views.
pub struct Shared {
    pub peak_l: AtomicF32,
    pub peak_r: AtomicF32,
}

impl Shared {
    fn new() -> Self {
        Self {
            peak_l: AtomicF32::new(0.0),
            peak_r: AtomicF32::new(0.0),
        }
    }
}

pub struct Nanometers {
    params: Arc<NanometersParams>,
    shared: Arc<Shared>,

    /// Per-sample multiplicative decay factor, computed from the host's sample rate in
    /// `initialize` so the visible decay rate is sample-rate-independent.
    peak_decay_per_sample: f32,
}

#[derive(Params)]
pub struct NanometersParams {
    #[persist = "editor-state"]
    editor_state: Arc<EditorState>,
}

impl Default for Nanometers {
    fn default() -> Self {
        Self {
            params: Arc::new(NanometersParams::default()),
            shared: Arc::new(Shared::new()),
            peak_decay_per_sample: 1.0,
        }
    }
}

impl Default for NanometersParams {
    fn default() -> Self {
        Self {
            editor_state: EditorState::from_size((INITIAL_WIDTH, INITIAL_HEIGHT)),
        }
    }
}

impl Plugin for Nanometers {
    const NAME: &'static str = "nanometers";
    const VENDOR: &'static str = "willeasp";
    const URL: &'static str = "https://github.com/willeasp/nanometers";
    const EMAIL: &'static str = "wille.asp@live.se";
    const VERSION: &'static str = env!("CARGO_PKG_VERSION");

    const AUDIO_IO_LAYOUTS: &'static [AudioIOLayout] = &[AudioIOLayout {
        main_input_channels: NonZeroU32::new(2),
        main_output_channels: NonZeroU32::new(2),
        ..AudioIOLayout::const_default()
    }];

    const SAMPLE_ACCURATE_AUTOMATION: bool = false;

    type SysExMessage = ();
    type BackgroundTask = ();

    fn params(&self) -> Arc<dyn Params> {
        self.params.clone()
    }

    fn editor(&mut self, _async_executor: AsyncExecutor<Self>) -> Option<Box<dyn Editor>> {
        Some(Box::new(NanometersEditor {
            params: Arc::clone(&self.params),
            shared: Arc::clone(&self.shared),

            // macOS uses the system scale factor; on Win/Linux we wait for the host to tell us.
            #[cfg(target_os = "macos")]
            scaling_factor: AtomicCell::new(None),
            #[cfg(not(target_os = "macos"))]
            scaling_factor: AtomicCell::new(Some(1.0)),
        }))
    }

    fn initialize(
        &mut self,
        _audio_io_layout: &AudioIOLayout,
        buffer_config: &BufferConfig,
        _context: &mut impl InitContext<Self>,
    ) -> bool {
        // Solve `decay^N = 0.25` for `decay`, where N = sample_rate * decay_ms / 1000.
        // Equivalently `decay = 0.25.powf(1 / N)`.
        let samples_for_12db_drop = buffer_config.sample_rate as f64 * PEAK_DECAY_MS / 1000.0;
        self.peak_decay_per_sample = 0.25_f64.powf(samples_for_12db_drop.recip()) as f32;
        true
    }

    fn process(
        &mut self,
        buffer: &mut Buffer,
        _aux: &mut AuxiliaryBuffers,
        _context: &mut impl ProcessContext<Self>,
    ) -> ProcessStatus {
        // Skip metering work when the GUI isn't open — host still gets a passthrough.
        if !self.params.editor_state.is_open() {
            return ProcessStatus::Normal;
        }

        let decay = self.peak_decay_per_sample;
        let mut peak_l = self.shared.peak_l.load(Ordering::Relaxed);
        let mut peak_r = self.shared.peak_r.load(Ordering::Relaxed);

        for channel_samples in buffer.iter_samples() {
            for (ch, sample) in channel_samples.into_iter().enumerate() {
                let abs = sample.abs();
                match ch {
                    0 => peak_l = if abs > peak_l { abs } else { peak_l * decay },
                    1 => peak_r = if abs > peak_r { abs } else { peak_r * decay },
                    _ => {}
                }
            }
        }

        self.shared.peak_l.store(peak_l, Ordering::Relaxed);
        self.shared.peak_r.store(peak_r, Ordering::Relaxed);

        ProcessStatus::Normal
    }
}

impl ClapPlugin for Nanometers {
    const CLAP_ID: &'static str = "com.willeasp.nanometers";
    const CLAP_DESCRIPTION: Option<&'static str> = Some(
        "Chill open-source audio meter plugin with waveform, spectrum, and stereo visualizations.",
    );
    const CLAP_MANUAL_URL: Option<&'static str> = Some(Self::URL);
    const CLAP_SUPPORT_URL: Option<&'static str> = None;
    const CLAP_FEATURES: &'static [ClapFeature] = &[
        ClapFeature::AudioEffect,
        ClapFeature::Analyzer,
        ClapFeature::Stereo,
    ];
}

nih_export_clap!(Nanometers);

// ────────────────────────────────────────────────────────────────────────────────────────
// Editor & window — wgpu setup, render loop, raw-window-handle 0.5↔0.6 plumbing.
// Adapted from nih-plug's byo_gui_wgpu example.
// ────────────────────────────────────────────────────────────────────────────────────────

#[derive(Debug, Serialize, Deserialize)]
pub struct EditorState {
    #[serde(with = "nih_plug::params::persist::serialize_atomic_cell")]
    size: AtomicCell<(u32, u32)>,
    #[serde(skip)]
    open: AtomicBool,
}

impl EditorState {
    fn from_size(size: (u32, u32)) -> Arc<Self> {
        Arc::new(Self {
            size: AtomicCell::new(size),
            open: AtomicBool::new(false),
        })
    }

    fn size(&self) -> (u32, u32) {
        self.size.load()
    }

    fn is_open(&self) -> bool {
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

struct NanometersEditor {
    params: Arc<NanometersParams>,
    shared: Arc<Shared>,
    scaling_factor: AtomicCell<Option<f32>>,
}

impl Editor for NanometersEditor {
    fn spawn(
        &self,
        parent: ParentWindowHandle,
        context: Arc<dyn GuiContext>,
    ) -> Box<dyn std::any::Any + Send> {
        let (unscaled_width, unscaled_height) = self.params.editor_state.size();
        let scaling_factor = self.scaling_factor.load();
        let gui_context = Arc::clone(&context);
        let params = Arc::clone(&self.params);
        let shared = Arc::clone(&self.shared);

        let window = baseview::Window::open_parented(
            &ParentWindowHandleAdapter(parent),
            WindowOpenOptions {
                title: String::from("nanometers"),
                size: baseview::Size::new(unscaled_width as f64, unscaled_height as f64),
                scale: scaling_factor
                    .map(|f| WindowScalePolicy::ScaleFactor(f as f64))
                    .unwrap_or(WindowScalePolicy::SystemScaleFactor),
                ..Default::default()
            },
            move |window: &mut baseview::Window<'_>| -> RenderWindow {
                RenderWindow::new(
                    window,
                    gui_context,
                    params,
                    shared,
                    scaling_factor.unwrap_or(1.0),
                )
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

// `WindowHandle` stores raw pointers — the parent window pointer the host gave us is `Send`
// at the API contract level (hosts may close us from any thread), so this is sound.
unsafe impl Send for EditorHandle {}

impl Drop for EditorHandle {
    fn drop(&mut self) {
        self.state.open.store(false, Ordering::Release);
        self.window.close();
    }
}

struct RenderWindow {
    #[allow(dead_code)]
    gui_context: Arc<dyn GuiContext>,
    #[allow(dead_code)]
    params: Arc<NanometersParams>,
    #[allow(dead_code)]
    shared: Arc<Shared>,

    device: wgpu::Device,
    queue: wgpu::Queue,
    surface: wgpu::Surface<'static>,
    surface_config: wgpu::SurfaceConfiguration,
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

        Self {
            gui_context,
            params,
            shared,
            device,
            queue,
            surface,
            surface_config,
        }
    }

    fn reconfigure_surface(&mut self) {
        self.surface.configure(&self.device, &self.surface_config);
    }
}

impl baseview::WindowHandler for RenderWindow {
    fn on_frame(&mut self, window: &mut baseview::Window) {
        let mut recreate_surface = false;
        let frame = match self.surface.get_current_texture() {
            wgpu::CurrentSurfaceTexture::Success(texture) => Some(texture),
            wgpu::CurrentSurfaceTexture::Occluded | wgpu::CurrentSurfaceTexture::Timeout => return,
            wgpu::CurrentSurfaceTexture::Suboptimal(_) | wgpu::CurrentSurfaceTexture::Outdated => {
                None
            }
            wgpu::CurrentSurfaceTexture::Validation => {
                unreachable!("no validation error scope registered")
            }
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

        {
            let _rpass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
                label: Some("nanometers-clear"),
                color_attachments: &[Some(wgpu::RenderPassColorAttachment {
                    view: &view,
                    resolve_target: None,
                    ops: wgpu::Operations {
                        // Near-black with a faint blue tint. Will become a real background once
                        // we have visualizations to render on top.
                        load: wgpu::LoadOp::Clear(wgpu::Color {
                            r: 0.012,
                            g: 0.013,
                            b: 0.020,
                            a: 1.0,
                        }),
                        store: wgpu::StoreOp::Store,
                    },
                    depth_slice: None,
                })],
                depth_stencil_attachment: None,
                timestamp_writes: None,
                occlusion_query_set: None,
                multiview_mask: None,
            });
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
// raw-window-handle 0.5 ↔ 0.6 plumbing.
// baseview is on rwh 0.5, wgpu 29 wants rwh 0.6. We bridge the two by hand.
// Copy-pasted from nih-plug's byo_gui_wgpu example.
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
