use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::ffi::c_void;
use std::ptr;
use std::rc::Rc;

use cocoa::appkit::{
    NSApp, NSApplication, NSApplicationActivationPolicyRegular, NSBackingStoreBuffered,
    NSPasteboard, NSView, NSWindow, NSWindowStyleMask,
};
use cocoa::base::{id, nil, BOOL, NO, YES};
use cocoa::foundation::{NSAutoreleasePool, NSPoint, NSRect, NSSize, NSString};
use core_foundation::runloop::{
    __CFRunLoopTimer, kCFRunLoopDefaultMode, CFRunLoop, CFRunLoopTimer, CFRunLoopTimerContext,
};
use keyboard_types::KeyboardEvent;
use objc::class;
use objc::{msg_send, runtime::Object, sel, sel_impl};
use raw_window_handle::{
    AppKitDisplayHandle, AppKitWindowHandle, HasRawDisplayHandle, HasRawWindowHandle,
    RawDisplayHandle, RawWindowHandle,
};

use crate::{
    Event, EventStatus, MouseCursor, Size, WindowHandler, WindowInfo, WindowOpenOptions,
    WindowScalePolicy,
};

use super::keyboard::KeyboardState;
use super::view::{create_view, BASEVIEW_STATE_IVAR};

#[cfg(feature = "opengl")]
use crate::gl::{GlConfig, GlContext};

#[link(name = "Foundation", kind = "framework")]
extern "C" {
    /// The run-loop mode set that keeps a scheduled source firing during modal loops (live resize,
    /// menu tracking) — so the display link doesn't stall while the user drags the window edge.
    static NSRunLoopCommonModes: id;
}

pub struct WindowHandle {
    state: Rc<WindowState>,
}

impl WindowHandle {
    pub fn close(&mut self) {
        self.state.window_inner.close();
    }

    pub fn is_open(&self) -> bool {
        self.state.window_inner.open.get()
    }
}

unsafe impl HasRawWindowHandle for WindowHandle {
    fn raw_window_handle(&self) -> RawWindowHandle {
        self.state.window_inner.raw_window_handle()
    }
}

pub(super) struct WindowInner {
    open: Cell<bool>,

    /// Only set if we created the parent window, i.e. we are running in
    /// parentless mode
    ns_app: Cell<Option<id>>,
    /// Only set if we created the parent window, i.e. we are running in
    /// parentless mode
    ns_window: Cell<Option<id>>,

    /// Only set when running in parented mode.
    parent_ns_window: Option<id>,

    /// Our subclassed NSView
    ns_view: id,

    #[cfg(feature = "opengl")]
    pub(super) gl_context: Option<GlContext>,
}

impl WindowInner {
    pub(super) fn close(&self) {
        if self.open.get() {
            self.open.set(false);
            unsafe {
                // Take back ownership of the NSView's Rc<WindowState>
                let state_ptr: *const c_void = *(*self.ns_view).get_ivar(BASEVIEW_STATE_IVAR);
                let window_state = Rc::from_raw(state_ptr as *mut WindowState);

                // Stop the frame driver before the state is dropped, so no callback fires into
                // freed state. Invalidate unschedules the link from the run loop synchronously.
                if let Some(display_link) = window_state.display_link.take() {
                    let () = msg_send![display_link, invalidate];
                    let () = msg_send![display_link, release];
                }
                if let Some(frame_timer) = window_state.frame_timer.take() {
                    CFRunLoop::get_current().remove_timer(&frame_timer, kCFRunLoopDefaultMode);
                }

                // Deregister NSView from NotificationCenter.
                let notification_center: id =
                    msg_send![class!(NSNotificationCenter), defaultCenter];
                let () = msg_send![notification_center, removeObserver:self.ns_view];

                drop(window_state);

                // Close the window if in non-parented mode
                if let Some(ns_window) = self.ns_window.take() {
                    ns_window.close();
                }

                // Ensure that the NSView is detached from the parent window
                self.ns_view.removeFromSuperview();
                let () = msg_send![self.ns_view as id, release];

                // If in non-parented mode, we want to also quit the app altogether
                let app = self.ns_app.take();
                if let Some(app) = app {
                    app.stop_(app);
                }
            }
        }
    }

    fn raw_window_handle(&self) -> RawWindowHandle {
        if self.open.get() {
            let ns_window =
                self.ns_window.get().or(self.parent_ns_window).unwrap_or(ptr::null_mut())
                    as *mut c_void;

            let mut handle = AppKitWindowHandle::empty();
            handle.ns_window = ns_window;
            handle.ns_view = self.ns_view as *mut c_void;

            return RawWindowHandle::AppKit(handle);
        }

        RawWindowHandle::AppKit(AppKitWindowHandle::empty())
    }
}

pub struct Window<'a> {
    inner: &'a WindowInner,
}

impl<'a> Window<'a> {
    pub fn open_parented<P, H, B>(parent: &P, options: WindowOpenOptions, build: B) -> WindowHandle
    where
        P: HasRawWindowHandle,
        H: WindowHandler + 'static,
        B: FnOnce(&mut crate::Window) -> H,
        B: Send + 'static,
    {
        let pool = unsafe { NSAutoreleasePool::new(nil) };

        let scaling = match options.scale {
            WindowScalePolicy::ScaleFactor(scale) => scale,
            WindowScalePolicy::SystemScaleFactor => 1.0,
        };

        let window_info = WindowInfo::from_logical_size(options.size, scaling);

        let handle = if let RawWindowHandle::AppKit(handle) = parent.raw_window_handle() {
            handle
        } else {
            panic!("Not a macOS window");
        };

        let ns_view = unsafe { create_view(&options) };

        let window_inner = WindowInner {
            open: Cell::new(true),
            ns_app: Cell::new(None),
            ns_window: Cell::new(None),
            parent_ns_window: if handle.ns_window.is_null() {
                None
            } else {
                Some(handle.ns_window.cast())
            },
            ns_view,

            #[cfg(feature = "opengl")]
            gl_context: options
                .gl_config
                .map(|gl_config| Self::create_gl_context(None, ns_view, gl_config)),
        };

        let window_handle = Self::init(window_inner, window_info, build);

        unsafe {
            let _: id = msg_send![handle.ns_view as *mut Object, addSubview: ns_view];

            let () = msg_send![pool, drain];
        }

        window_handle
    }

    pub fn open_blocking<H, B>(options: WindowOpenOptions, build: B)
    where
        H: WindowHandler + 'static,
        B: FnOnce(&mut crate::Window) -> H,
        B: Send + 'static,
    {
        let pool = unsafe { NSAutoreleasePool::new(nil) };

        // It seems prudent to run NSApp() here before doing other
        // work. It runs [NSApplication sharedApplication], which is
        // what is run at the very start of the Xcode-generated main
        // function of a cocoa app according to:
        // https://developer.apple.com/documentation/appkit/nsapplication
        let app = unsafe { NSApp() };

        unsafe {
            app.setActivationPolicy_(NSApplicationActivationPolicyRegular);
        }

        let scaling = match options.scale {
            WindowScalePolicy::ScaleFactor(scale) => scale,
            WindowScalePolicy::SystemScaleFactor => 1.0,
        };

        let window_info = WindowInfo::from_logical_size(options.size, scaling);

        let rect = NSRect::new(
            NSPoint::new(0.0, 0.0),
            NSSize::new(window_info.logical_size().width, window_info.logical_size().height),
        );

        let ns_window = unsafe {
            let ns_window = NSWindow::alloc(nil).initWithContentRect_styleMask_backing_defer_(
                rect,
                NSWindowStyleMask::NSTitledWindowMask
                    | NSWindowStyleMask::NSClosableWindowMask
                    | NSWindowStyleMask::NSMiniaturizableWindowMask,
                NSBackingStoreBuffered,
                NO,
            );
            ns_window.center();

            let title = NSString::alloc(nil).init_str(&options.title).autorelease();
            ns_window.setTitle_(title);

            ns_window.makeKeyAndOrderFront_(nil);

            ns_window
        };

        let ns_view = unsafe { create_view(&options) };

        let window_inner = WindowInner {
            open: Cell::new(true),
            ns_app: Cell::new(Some(app)),
            ns_window: Cell::new(Some(ns_window)),
            parent_ns_window: None,
            ns_view,

            #[cfg(feature = "opengl")]
            gl_context: options
                .gl_config
                .map(|gl_config| Self::create_gl_context(Some(ns_window), ns_view, gl_config)),
        };

        let _ = Self::init(window_inner, window_info, build);

        unsafe {
            ns_window.setContentView_(ns_view);
            ns_window.setDelegate_(ns_view);

            let () = msg_send![pool, drain];

            app.run();
        }
    }

    fn init<H, B>(window_inner: WindowInner, window_info: WindowInfo, build: B) -> WindowHandle
    where
        H: WindowHandler + 'static,
        B: FnOnce(&mut crate::Window) -> H,
        B: Send + 'static,
    {
        let mut window = crate::Window::new(Window { inner: &window_inner });
        let window_handler = Box::new(build(&mut window));

        let ns_view = window_inner.ns_view;

        let window_state = Rc::new(WindowState {
            window_inner,
            window_handler: RefCell::new(window_handler),
            keyboard_state: KeyboardState::new(),
            frame_timer: Cell::new(None),
            display_link: Cell::new(None),
            window_info: Cell::new(window_info),
            deferred_events: RefCell::default(),
            log_frame_ts: nano_debug_enabled(),
            target_log: RefCell::new(TargetTsLog::new()),
        });

        let window_state_ptr = Rc::into_raw(Rc::clone(&window_state));

        unsafe {
            (*ns_view).set_ivar(BASEVIEW_STATE_IVAR, window_state_ptr as *const c_void);

            WindowState::setup_frame_driver(window_state_ptr);
        }

        WindowHandle { state: window_state }
    }

    pub fn close(&mut self) {
        self.inner.close();
    }

    pub fn has_focus(&mut self) -> bool {
        unsafe {
            let view = self.inner.ns_view.as_mut().unwrap();
            let window: id = msg_send![view, window];
            if window == nil {
                return false;
            };
            let first_responder: id = msg_send![window, firstResponder];
            let is_key_window: BOOL = msg_send![window, isKeyWindow];
            let is_focused: BOOL = msg_send![view, isEqual: first_responder];
            is_key_window == YES && is_focused == YES
        }
    }

    pub fn focus(&mut self) {
        unsafe {
            let view = self.inner.ns_view.as_mut().unwrap();
            let window: id = msg_send![view, window];
            if window != nil {
                msg_send![window, makeFirstResponder:view]
            }
        }
    }

    pub fn resize(&mut self, size: Size) {
        if self.inner.open.get() {
            // NOTE: macOS gives you a personal rave if you pass in fractional pixels here. Even
            // though the size is in fractional pixels.
            let size = NSSize::new(size.width.round(), size.height.round());

            unsafe { NSView::setFrameSize(self.inner.ns_view, size) };
            unsafe {
                let _: () = msg_send![self.inner.ns_view, setNeedsDisplay: YES];
            }

            // When using OpenGL the `NSOpenGLView` needs to be resized separately? Why? Because
            // macOS.
            #[cfg(feature = "opengl")]
            if let Some(gl_context) = &self.inner.gl_context {
                gl_context.resize(size);
            }

            // If this is a standalone window then we'll also need to resize the window itself
            if let Some(ns_window) = self.inner.ns_window.get() {
                unsafe { NSWindow::setContentSize_(ns_window, size) };
            }
        }
    }

    pub fn set_mouse_cursor(&mut self, _mouse_cursor: MouseCursor) {
        todo!()
    }

    #[cfg(feature = "opengl")]
    pub fn gl_context(&self) -> Option<&GlContext> {
        self.inner.gl_context.as_ref()
    }

    #[cfg(feature = "opengl")]
    fn create_gl_context(ns_window: Option<id>, ns_view: id, config: GlConfig) -> GlContext {
        let mut handle = AppKitWindowHandle::empty();
        handle.ns_window = ns_window.unwrap_or(ptr::null_mut()) as *mut c_void;
        handle.ns_view = ns_view as *mut c_void;
        let handle = RawWindowHandle::AppKit(handle);

        unsafe { GlContext::create(&handle, config).expect("Could not create OpenGL context") }
    }
}

/// DIAGNOSTIC ONLY (gated by `~/.nano-debug`): accumulates the display link's `targetTimestamp`
/// deltas — the instant each frame is predicted to be ON SCREEN — and logs mean/min/max every 240
/// frames, mirroring the editor's `[nano-frames]` wall-clock line. Comparing the two distributions
/// answers the open question: does a lumpy host (FL) pollute our display-link CLOCK, or only the
/// on-screen presentation? Costs nothing when the marker is absent (`WindowState::log_frame_ts`).
struct TargetTsLog {
    last: f64,
    count: u32,
    sum_ms: f64,
    min_ms: f64,
    max_ms: f64,
}

impl TargetTsLog {
    fn new() -> Self {
        Self { last: 0.0, count: 0, sum_ms: 0.0, min_ms: f64::MAX, max_ms: 0.0 }
    }

    fn tick(&mut self, target: f64) {
        if self.last > 0.0 {
            let dt = (target - self.last) * 1000.0;
            self.count += 1;
            self.sum_ms += dt;
            self.min_ms = self.min_ms.min(dt);
            self.max_ms = self.max_ms.max(dt);
            if self.count >= 240 {
                let mean = self.sum_ms / self.count as f64;
                diag_log(&format!(
                    "[nano-target] {} frames: mean {:.2} ms ({:.1} fps), min {:.2}, max {:.2}",
                    self.count,
                    mean,
                    1000.0 / mean,
                    self.min_ms,
                    self.max_ms
                ));
                self.count = 0;
                self.sum_ms = 0.0;
                self.min_ms = f64::MAX;
                self.max_ms = 0.0;
            }
        }
        self.last = target;
    }
}

/// `true` when the `~/.nano-debug` marker exists — checked ONCE at window construction. Mirrors the
/// nanometers crate's `diag_enabled` (baseview can't reach it), kept dead-simple and self-contained.
fn nano_debug_enabled() -> bool {
    std::env::var_os("HOME")
        .map(|h| std::path::Path::new(&h).join(".nano-debug").exists())
        .unwrap_or(false)
}

/// Append a diagnostic line to `~/Library/Logs/nanometers.log` (the sandbox-allowed path) and
/// stderr. Best-effort; mirrors the nanometers crate's `diag_log` so lines interleave in one file.
fn diag_log(line: &str) {
    eprintln!("{line}");
    if let Some(home) = std::env::var_os("HOME") {
        use std::io::Write;
        let path = std::path::Path::new(&home).join("Library/Logs/nanometers.log");
        if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(path) {
            let _ = writeln!(f, "{line}");
        }
    }
}

pub(super) struct WindowState {
    pub(super) window_inner: WindowInner,
    window_handler: RefCell<Box<dyn WindowHandler>>,
    keyboard_state: KeyboardState,
    frame_timer: Cell<Option<CFRunLoopTimer>>,
    /// AppKit display link driving `on_frame` at the display refresh (macOS 14+). Retained `id`;
    /// invalidated + released on close. `None` when we fell back to `frame_timer`.
    display_link: Cell<Option<id>>,
    /// The last known window info for this window.
    pub window_info: Cell<WindowInfo>,

    /// Events that will be triggered at the end of `window_handler`'s borrow.
    deferred_events: RefCell<VecDeque<Event>>,

    /// Diagnostics (gated by `~/.nano-debug`, checked once): log the display-link `targetTimestamp`
    /// cadence to compare against the editor's wall-clock frame interval. See `TargetTsLog`.
    log_frame_ts: bool,
    target_log: RefCell<TargetTsLog>,
}

impl WindowState {
    /// Gets the `WindowState` held by a given `NSView`.
    ///
    /// This method returns a cloned `Rc<WindowState>` rather than just a `&WindowState`, since the
    /// original `Rc<WindowState>` owned by the `NSView` can be dropped at any time
    /// (including during an event handler).
    pub(super) unsafe fn from_view(view: &Object) -> Rc<WindowState> {
        let state_ptr: *const c_void = *view.get_ivar(BASEVIEW_STATE_IVAR);

        let state_rc = Rc::from_raw(state_ptr as *const WindowState);
        let state = Rc::clone(&state_rc);
        let _ = Rc::into_raw(state_rc);

        state
    }

    /// Trigger the event immediately and return the event status.
    /// Will panic if `window_handler` is already borrowed (see `trigger_deferrable_event`).
    pub(super) fn trigger_event(&self, event: Event) -> EventStatus {
        let mut window = crate::Window::new(Window { inner: &self.window_inner });
        let mut window_handler = self.window_handler.borrow_mut();
        let status = window_handler.on_event(&mut window, event);
        self.send_deferred_events(window_handler.as_mut());
        status
    }

    /// Trigger the event immediately if `window_handler` can be borrowed mutably,
    /// otherwise add the event to a queue that will be cleared once `window_handler`'s mutable borrow ends.
    /// As this method might result in the event triggering asynchronously, it can't reliably return the event status.
    pub(super) fn trigger_deferrable_event(&self, event: Event) {
        if let Ok(mut window_handler) = self.window_handler.try_borrow_mut() {
            let mut window = crate::Window::new(Window { inner: &self.window_inner });
            window_handler.on_event(&mut window, event);
            self.send_deferred_events(window_handler.as_mut());
        } else {
            self.deferred_events.borrow_mut().push_back(event);
        }
    }

    pub(super) fn trigger_frame(&self) {
        let mut window = crate::Window::new(Window { inner: &self.window_inner });
        let mut window_handler = self.window_handler.borrow_mut();
        window_handler.on_frame(&mut window);
        self.send_deferred_events(window_handler.as_mut());
    }

    /// `true` if the `~/.nano-debug` diagnostics are on (set once at construction). Lets the display
    /// link callback skip the `targetTimestamp` read entirely in shipped builds.
    pub(super) fn frame_ts_logging(&self) -> bool {
        self.log_frame_ts
    }

    /// Record one display-link `targetTimestamp` (seconds, the predicted on-screen instant of the
    /// upcoming frame). DIAGNOSTIC ONLY — see `TargetTsLog`.
    pub(super) fn log_target_ts(&self, target: f64) {
        self.target_log.borrow_mut().tick(target);
    }

    pub(super) fn keyboard_state(&self) -> &KeyboardState {
        &self.keyboard_state
    }

    pub(super) fn process_native_key_event(&self, event: *mut Object) -> Option<KeyboardEvent> {
        self.keyboard_state.process_native_event(event)
    }

    /// Drive `on_frame` from the display's refresh. Prefer an AppKit display link
    /// (`-[NSView displayLinkWithTarget:selector:]`, macOS 14+): it is vsync-locked and adapts to
    /// the refresh rate of whichever display the window is on — a plugin window gets dragged between
    /// a 120 Hz laptop panel and a 60 Hz external, which a fixed timer can't follow. Fall back to the
    /// 66.7 Hz `CFRunLoopTimer` on older systems.
    unsafe fn setup_frame_driver(window_state_ptr: *const WindowState) {
        let view: id = (*window_state_ptr).window_inner.ns_view;
        let responds: BOOL =
            msg_send![view, respondsToSelector: sel!(displayLinkWithTarget:selector:)];
        if responds == YES {
            let display_link: id =
                msg_send![view, displayLinkWithTarget: view selector: sel!(displayLinkFired:)];
            if display_link != nil {
                let _: id = msg_send![display_link, retain];
                let run_loop: id = msg_send![class!(NSRunLoop), currentRunLoop];
                let () = msg_send![display_link, addToRunLoop: run_loop forMode: NSRunLoopCommonModes];
                (*window_state_ptr).display_link.set(Some(display_link));
                return;
            }
        }
        Self::setup_timer(window_state_ptr);
    }

    unsafe fn setup_timer(window_state_ptr: *const WindowState) {
        extern "C" fn timer_callback(_: *mut __CFRunLoopTimer, window_state_ptr: *mut c_void) {
            unsafe {
                let window_state = &*(window_state_ptr as *const WindowState);

                window_state.trigger_frame();
            }
        }

        let mut timer_context = CFRunLoopTimerContext {
            version: 0,
            info: window_state_ptr as *mut c_void,
            retain: None,
            release: None,
            copyDescription: None,
        };

        let timer = CFRunLoopTimer::new(0.0, 0.015, 0, 0, timer_callback, &mut timer_context);

        CFRunLoop::get_current().add_timer(&timer, kCFRunLoopDefaultMode);

        (*window_state_ptr).frame_timer.set(Some(timer));
    }

    fn send_deferred_events(&self, window_handler: &mut dyn WindowHandler) {
        let mut window = crate::Window::new(Window { inner: &self.window_inner });
        loop {
            let next_event = self.deferred_events.borrow_mut().pop_front();
            if let Some(event) = next_event {
                window_handler.on_event(&mut window, event);
            } else {
                break;
            }
        }
    }
}

unsafe impl<'a> HasRawWindowHandle for Window<'a> {
    fn raw_window_handle(&self) -> RawWindowHandle {
        self.inner.raw_window_handle()
    }
}

unsafe impl<'a> HasRawDisplayHandle for Window<'a> {
    fn raw_display_handle(&self) -> RawDisplayHandle {
        RawDisplayHandle::AppKit(AppKitDisplayHandle::empty())
    }
}

pub fn copy_to_clipboard(string: &str) {
    unsafe {
        let pb = NSPasteboard::generalPasteboard(nil);

        let ns_str = NSString::alloc(nil).init_str(string);

        pb.clearContents();
        pb.setString_forType(ns_str, cocoa::appkit::NSPasteboardTypeString);
    }
}
