//! The Module-host contract (ADRs 0002 / 0003 / 0004).
//!
//! A Module is a self-contained visualization occupying one viewport rectangle; it owns its DSP
//! state and GPU pipeline(s). The host (`RenderWindow`) drains the audio ring once per frame and
//! drives every Module through these phases:
//!
//! 1. `update` — fold this frame's new samples into GUI-side state; upload to owned GPU buffers.
//! 2. `prepare` (optional) — encode any OWN offscreen passes (e.g. the Waveform's MSAA contour
//!    target, ADR 0007) before the host opens its shared single-sample pass.
//! 3. `render` — draw (or composite the resolved offscreen result) into the Module's viewport,
//!    inside the host's shared pass.
//!
//! `prepare` elaborates ADR 0002's two-phase sketch: the offscreen draw is part of "render" but
//! needs `CommandEncoder` access the shared `RenderPass` can't give. See ADR 0002's trait block
//! and `docs/specs/waveform-module.md` §8.

use crate::StereoFrame;
use atomic_float::AtomicF32;

/// Concrete Modules live under this namespace alongside the contract they implement.
pub mod loudness;
pub mod oscilloscope;
pub mod waveform;

/// An INTEGER-aligned physical-pixel rectangle on the surface. The host computes integer column
/// boundaries (see `RenderWindow`) so `x`/`y`/`w`/`h` are whole f32s and convert exactly to wgpu's
/// u32 `set_scissor_rect` via `as u32`. One per column is handed to a Module each frame.
///
/// Before each Module's `render`, the host sets BOTH the GPU **viewport** and the **scissor** to
/// this rect: `set_viewport` affine-maps full-viewport clip space `[-1, 1]` into the column for
/// free, and `set_scissor_rect` hard-clips (viewport mapping alone doesn't discard out-of-rect
/// points/lines). So a Module emits geometry in plain `[-1, 1]` and lands column-local with no
/// per-Module transform. Pixel-space draws (e.g. `wgpu_text`) must still account for the viewport
/// origin/size in their own projection — they don't get the affine map. [`Rect::clip_transform`]
/// is available for that case.
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
    /// Most Modules don't need this — the host's `set_viewport` already maps `[-1, 1]` into the
    /// column. It's here for Modules that bypass that (pixel-space text projections, hit-testing).
    pub fn clip_transform(&self, surface_w: f32, surface_h: f32) -> [f32; 4] {
        let sx = self.w / surface_w;
        let ox = (2.0 * self.x + self.w) / surface_w - 1.0;
        let sy = self.h / surface_h;
        let oy = 1.0 - (2.0 * self.y + self.h) / surface_h;
        [sx, ox, sy, oy]
    }
}

/// Cheap scalars the audio thread computes because they're broadly useful (ADR 0002). This is NOT
/// where Module measurements live — Modules derive their own from `FrameContext::new`. It stays
/// tiny by design (today: just the decaying peak).
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
/// oldest→newest. `sample_rate` / `mono` are host metadata read once at `initialize` time, constant
/// per stream; `sample_rate == 0.0` means unknown (Modules idle).
///
/// `mono` is load-bearing for loudness: the plugin duplicates a mono input to L = R, so a stereo
/// sum of that reads +3 LU hot — a mono stream must be measured as a single channel. Never treat
/// `mono` as cosmetic.
pub struct FrameContext<'a> {
    pub new: &'a [StereoFrame],
    pub meas: &'a Measurements,
    pub sample_rate: f32,
    pub mono: bool,
    /// Seconds since the previous `on_frame`, measured at its ENTRY (before the Fifo-present block) —
    /// the clean frame interval. Modules must use this for cadence/scroll timing rather than sampling
    /// the clock inside `prepare`, which runs after a variable-latency present wait. 0.0 on the first.
    pub frame_dt: f64,
}

/// What a Module reports back to the host's pointer-grab state machine (ADR 0004). A Module must
/// return `Ignored` for events it doesn't consume, so the host can turn a body-press into a reorder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventStatus {
    Captured,
    Ignored,
}

pub trait Module {
    /// Phase 1 — fold this frame's new samples into GUI-side state; upload to owned GPU buffers.
    fn update(&mut self, ctx: &FrameContext, queue: &wgpu::Queue);

    /// Phase 2a (optional) — encode any OWN offscreen passes into `encoder` before the host's
    /// shared single-sample pass opens (e.g. the Waveform's MSAA contour target, ADR 0007).
    /// Default: no-op, for Modules that draw straight into the shared pass (Loudness, Oscilloscope).
    fn prepare(
        &mut self,
        _device: &wgpu::Device,
        _queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        _viewport: Rect,
    ) {
    }

    /// Phase 2b — draw (or composite the resolved offscreen result) into `viewport` within the
    /// host's shared pass. The host has already set BOTH the GPU viewport and the scissor to
    /// `viewport` (see [`Rect`]), so geometry in `[-1, 1]` lands column-local and clipped. `render`
    /// MUST set every pipeline-state it depends on (pipeline, all bind groups, vertex/index
    /// buffers) and must NOT rely on state left by a prior Module: the host guarantees only the
    /// viewport+scissor and the cleared/loaded attachment, and render order is otherwise arbitrary.
    fn render(&mut self, rpass: &mut wgpu::RenderPass, viewport: Rect);

    /// Pointer/keyboard inside this Module's viewport, in COLUMN-LOCAL coords (ADR 0004).
    fn on_event(&mut self, event: &baseview::Event, viewport: Rect) -> EventStatus;

    /// Opaque per-instance config persistence (ADR 0003). The host stores the bytes, never reads
    /// them. An unrecognized blob should leave the Module at its defaults rather than panic.
    fn save_config(&self) -> Vec<u8>;
    fn load_config(&mut self, bytes: &[u8]);
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
        // Right half occupies NDC x [0, 1]: scale 0.5, offset 0.5. Full height → (1, 0).
        let r = Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 };
        assert_eq!(r.clip_transform(800.0, 600.0), [0.5, 0.5, 1.0, 0.0]);
    }

    #[test]
    fn clip_transform_bottom_half_flips_y() {
        // Bottom half in pixels is the LOWER NDC band [-1, 0]: scale_y 0.5, offset_y -0.5.
        let r = Rect { x: 0.0, y: 300.0, w: 800.0, h: 300.0 };
        assert_eq!(r.clip_transform(800.0, 600.0), [1.0, 0.0, 0.5, -0.5]);
    }
}
