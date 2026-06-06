//! nano-dsp — the platform-free domain core of nanometers (ADR 0008).
//!
//! Everything here is pure: the audio→GUI value types, the envelope store, BS.1770 loudness,
//! spectral color, and the scroll control law. No `wgpu`, no `nih_plug`, no `baseview`, no
//! platform. The plugin, the TUI player, and the iOS app all link this crate; it is the seam the
//! monorepo exists to share.
//!
//! The `Module` trait itself does NOT live here: its methods name `wgpu` types, so it belongs to
//! the plugin (`nano-render`-to-be). Only the *data* a Module consumes — `FrameContext`,
//! `Measurements`, `Rect`, `StereoFrame` — sinks down to this crate.

use atomic_float::AtomicF32;

/// Loudness measurement DSP (ADR 0006). Pure, hand-rolled BS.1770; `ebur128` is a dev-dependency
/// test oracle, never a runtime one.
pub mod loudness;

/// The Waveform's GPU-free pieces (ADRs 0001 / 0002 / 0007): the base-bin envelope store, the
/// 3-band spectral-color filterbank + mapping, and the pure scroll control law.
pub mod waveform;

/// C-ABI facade for the iOS app (ADR 0008 / 0009). Gated behind `ffi` so the plugin/TUI never
/// compile it; cbindgen-equivalent header is hand-maintained at `include/nano_dsp.h` (Task 6).
#[cfg(feature = "ffi")]
pub mod ffi;

/// One interleaved L/R audio frame. The wire format of the audio→GUI ring (ADR 0002).
pub type StereoFrame = [f32; 2];

/// An INTEGER-aligned physical-pixel rectangle on the surface. Pure geometry (no wgpu).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect {
    pub x: f32,
    pub y: f32,
    pub w: f32,
    pub h: f32,
}

impl Rect {
    /// Map full-surface clip space `[-1, 1]` into this sub-rect, given the surface size in physical
    /// px. Returns `(scale_x, offset_x, scale_y, offset_y)` for `ndc' = scale * ndc + offset`. Y
    /// flips (pixel-y grows down, NDC-y grows up). A full-surface rect → identity `(1, 0, 1, 0)`.
    /// Most callers don't need this — a GPU host that calls `set_viewport` already maps `[-1, 1]`
    /// into the column for free. Use it for draws that bypass that map (pixel-space text
    /// projections, hit-testing).
    pub fn clip_transform(&self, surface_w: f32, surface_h: f32) -> [f32; 4] {
        let sx = self.w / surface_w;
        let ox = (2.0 * self.x + self.w) / surface_w - 1.0;
        let sy = self.h / surface_h;
        let oy = 1.0 - (2.0 * self.y + self.h) / surface_h;
        [sx, ox, sy, oy]
    }
}

/// Cheap scalars the audio thread computes because they're broadly useful (ADR 0002). Stays tiny by
/// design (today: just the decaying peak).
pub struct Measurements {
    pub peak_l: AtomicF32,
    pub peak_r: AtomicF32,
}

impl Measurements {
    pub fn new() -> Self {
        Self {
            peak_l: AtomicF32::new(0.0),
            peak_r: AtomicF32::new(0.0),
        }
    }
}

impl Default for Measurements {
    fn default() -> Self {
        Self::new()
    }
}

/// Fanned out to every Module each frame (ADR 0002). `new` is this frame's freshly drained samples,
/// oldest→newest. `sample_rate` / `mono` are host metadata read once at `initialize` time;
/// `sample_rate == 0.0` means unknown (Modules idle).
///
/// `mono` is load-bearing for loudness: the plugin duplicates a mono input to L = R, so a stereo
/// sum of that reads +3 LU hot — a mono stream must be measured as a single channel.
pub struct FrameContext<'a> {
    pub new: &'a [StereoFrame],
    pub meas: &'a Measurements,
    pub sample_rate: f32,
    pub mono: bool,
    /// Seconds since the previous frame. The editor renders on a dedicated thread paced by the
    /// swapchain at vblank (ADR 0008), so this is the steady inter-frame interval; currently
    /// informational (logged via `NANO_DEBUG_FRAMES`). 0.0 on the first frame.
    pub frame_dt: f64,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn clip_transform_full_surface_is_identity() {
        let r = Rect { x: 0.0, y: 0.0, w: 800.0, h: 600.0 };
        assert_eq!(r.clip_transform(800.0, 600.0), [1.0, 0.0, 1.0, 0.0]);
    }

    #[test]
    fn clip_transform_right_half() {
        let r = Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 };
        assert_eq!(r.clip_transform(800.0, 600.0), [0.5, 0.5, 1.0, 0.0]);
    }

    #[test]
    fn clip_transform_bottom_half_flips_y() {
        let r = Rect { x: 0.0, y: 300.0, w: 800.0, h: 300.0 };
        assert_eq!(r.clip_transform(800.0, 600.0), [1.0, 0.0, 0.5, -0.5]);
    }
}
