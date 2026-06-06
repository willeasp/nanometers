# iOS renders natively in SwiftUI and links only nano-dsp

ADR [0008] (`0008-workspace-crate-split-cross-platform.md`) sketched the iOS app as "a `staticlib`
linking `nano-render` + `nano-dsp` … wrapped by an Xcode project drawing into a `CAMetalLayer`."
While building out the iOS design (`docs/superpowers/specs/2026-06-06-nanometers-ios-design.md`) we
resolved that clause differently. This ADR records the change so the codebase and the accepted
decisions don't silently disagree.

## The decision

**The iOS app renders natively in SwiftUI (`Canvas` / `TimelineView`) and links only `nano-dsp`,
not `nano-render`.** The Rust↔Swift boundary is a small C-ABI facade over `nano-dsp`
(`nano_dsp_analyze`, `nano_dsp_integrated_lufs`, and a streaming short-term meter), packaged as
`NanoDSP.xcframework`. All UI, playback, and waveform drawing are Swift.

## Why

- **The reusable IP is the math, not the draw calls.** `nano-dsp` (band-split, BS.1770 color, the
  envelope store) is what's worth sharing across plugin/TUI/iOS. `nano-render` is wgpu plumbing for
  what amounts to a few hundred rounded rects — cheap in `Canvas`, expensive to reach through a
  wgpu/Metal/Xcode cross-build.
- **A file player doesn't need the scroll control law.** The reservoir/consume loop exists to
  reconcile live, bursty audio-block arrival against an independent render clock — the *plugin's*
  problem. A file player has a sample-accurate `AVAudioPlayerNode` clock and precomputed bins, so
  the close-up is a direct window into cached data.
- **Reusing `nano-render` would still leave two render paths on iOS** — the overview and the mini
  waveforms are native `Canvas` regardless (the handoff says so; you can't host a Metal layer per
  list row). Native everywhere is one path, not two.

## Consequences

- `nano-render` is **not** built or linked for iOS. The escape hatch stays open: if profiling shows
  the close-up can't hold 120 Hz ProMotion in `Canvas`, that single view can move to Metal — which
  is the point at which linking `nano-render` would actually pay for itself. Re-open this ADR then.
- This supersedes only the iOS-rendering clause of [0008]; the workspace split, the `nano-dsp`
  carve, and `apps/nano-tui` are unchanged and were executed in Phase 0.
- The iOS app gains a maintained C-ABI surface on `nano-dsp` (the `ffi` feature). Growing it is a
  deliberate vocabulary change, not a dumping ground.

[0008]: 0008-workspace-crate-split-cross-platform.md
