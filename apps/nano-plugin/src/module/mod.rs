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

/// The data types a Module consumes — `Rect`, `Measurements`, `FrameContext`, `StereoFrame` — now
/// live in `nano-dsp` (ADR 0008): platform-free, shared with the TUI and iOS. Re-exported here so
/// the concrete Modules keep referring to `super::{FrameContext, Rect, …}` unchanged. The `Module`
/// trait stays in this crate because its signatures name `wgpu` types.
pub use nano_dsp::{FrameContext, Measurements, Rect, StereoFrame};

/// Concrete Modules live under this namespace alongside the contract they implement.
pub mod loudness;
pub mod oscilloscope;
pub mod stereometer;
pub mod waveform;

/// Embedded OFL font (JetBrains Mono, tabular figures — digits don't jitter as values change), ADR
/// 0005. Shared by every Module and host overlay that renders text, so the ~200 KB TTF is embedded
/// once rather than per text-drawing site.
pub(crate) const FONT: &[u8] = include_bytes!("../../assets/fonts/JetBrainsMono-Regular.ttf");

/// What a Module reports back to the host's pointer-grab state machine (ADR 0004). A Module must
/// return `Ignored` for events it doesn't consume, so the host can turn a body-press into a reorder.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventStatus {
    Captured,
    Ignored,
}

pub trait Module {
    /// The fixed LOGICAL width this Module wants its column pinned to; `None` (the default) flexes
    /// (ADR 0003, amended). Read from the LIVE module at editor spawn and written over the persisted
    /// column width (`layout::reconcile_fixed_widths`) — never trusted from persisted bytes, so a
    /// sizing change in the module reflows old sessions instead of drawing into a stale column.
    fn intrinsic_width(&self) -> Option<f32> {
        None
    }

    /// Phase 1 — fold this frame's new samples into GUI-side state; upload to owned GPU buffers.
    fn update(&mut self, ctx: &FrameContext, queue: &wgpu::Queue);

    /// Phase 2a (optional) — encode any OWN offscreen passes into `encoder` before the host's
    /// shared single-sample pass opens (e.g. the Waveform's MSAA contour target, ADR 0007); also
    /// where per-frame buffer/text uploads happen. `scale` is the display backing scale (physical
    /// px ÷ logical px, 2.0 on Retina): the surface — and so `viewport` — is in PHYSICAL px, so a
    /// Module sizing text or padding in logical px must multiply by it or render half-size on 2×.
    /// Default: no-op, for Modules that draw straight into the shared pass (Oscilloscope).
    fn prepare(
        &mut self,
        _device: &wgpu::Device,
        _queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        _viewport: Rect,
        _scale: f32,
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
