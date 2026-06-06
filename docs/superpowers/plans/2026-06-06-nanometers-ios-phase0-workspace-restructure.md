# Nanometers iOS — Phase 0: Workspace Restructure + FFI Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Restructure the single `nanometers` crate into the ADR 0008 `apps/`+`crates/` workspace — carve out `nano-dsp` (the platform-free DSP core), relocate the plugin to `apps/nano-plugin`, extract the TUI to `apps/nano-tui`, and ship a `NanoDSP.xcframework` for the future iOS app — keeping the plugin and TUI green at every step.

**Architecture:** A bottom `crates/nano-dsp` library holds the pure domain (BS.1770 loudness, the base-bin envelope store, the 3-band spectral-color filterbank, the audio→GUI value types, and the scroll control law). Three shells under `apps/` link it: `nano-plugin` (today's nih-plug/CLAP/AU plugin), `nano-tui` (the terminal player), and later `nano-ios`. A feature-gated C-ABI facade in `nano-dsp` plus cbindgen + `xcodebuild -create-xcframework` produces the framework Swift links.

**Tech Stack:** Rust 2024 (cargo workspace, rustc 1.89 stable), nih-plug + clap-wrapper (AU via CMake), a hand-authored C header (the ABI is frozen and tiny; cbindgen needs nightly `expand` to see feature-gated code, so it's not on the required path), `xcodebuild -create-xcframework`, `swiftc` (smoke test).

**Branch:** `worktree-nano-ios`, based on current `main` (`d3da50b`). Work happens in this git worktree.

**Why "re-derive", not `git rebase`:** A complete carve already exists on branch `origin/claude/dev-player-iphone-audio-0C2dx` (commit `6e6e538`). It cannot be cleanly rebased onto current `main` — `main`'s render-thread/swapchain refactor edited the same module files. So this plan treats `6e6e538` as the **proven recipe** and re-applies its cut to `main`'s current files. Two reconciliations the recipe does NOT capture, verified against both trees:
> 1. `main`'s `FrameContext` gained a `frame_dt: f64` field (the recipe's is the older 4-field version). The new `nano-dsp` `FrameContext` MUST include `frame_dt`, and every `FrameContext { .. }` literal must set it.
> 2. `main` deleted the old `time_cursor`/TIME-mode scroll path. The surviving scroll-law fns (`choose_px_per_frame`, `consume_samples`) are byte-identical to the recipe, so they move as-is.

---

## File Structure

After Phase 0 the workspace is:

```
nanometers/                         (repo root — cargo workspace)
├── Cargo.toml                      members = crates/nano-dsp, apps/nano-plugin, apps/nano-tui, xtask
├── Cargo.lock
├── build.sh                        paths updated: auv2 now under apps/nano-plugin/
├── .cargo/config.toml              unchanged (xtask alias is package-name based)
├── rust-toolchain.toml             unchanged
├── crates/
│   └── nano-dsp/
│       ├── Cargo.toml              lib + staticlib; `ffi` feature; atomic_float dep; ebur128 dev-oracle
│       ├── cbindgen.toml           C header generation config (Task 5)
│       ├── build-xcframework.sh    cross-build + assemble NanoDSP.xcframework (Task 6)
│       ├── src/
│       │   ├── lib.rs              StereoFrame, Rect, Measurements, FrameContext (+frame_dt); mod decls
│       │   ├── loudness.rs         MOVED verbatim from nanometers/src/loudness.rs
│       │   ├── ffi.rs              NEW: C-ABI facade (Task 5), behind `#[cfg(feature = "ffi")]`
│       │   └── waveform/
│       │       ├── mod.rs          NEW: pub mod color/store + choose_px_per_frame/consume_samples + tests
│       │       ├── color.rs        MOVED verbatim from nanometers/src/module/waveform/color.rs
│       │       └── store.rs        MOVED verbatim from nanometers/src/module/waveform/store.rs
│       └── tests/
│           └── pure_core_standalone.rs   NEW: renderer-independence guard (recipe + frame_dt fix)
├── apps/
│   ├── nano-plugin/                MOVED from ./nanometers (package name STAYS "nanometers")
│   │   ├── Cargo.toml              nano-dsp dep added; nanoplayer bin/feature/deps removed
│   │   ├── auv2/                   MOVED from ./auv2 (CMake ../target path fixed)
│   │   └── src/                    lib.rs, editor.rs, standalone.rs, dev.rs, layout.rs, module/…
│   └── nano-tui/
│       ├── Cargo.toml              NEW: links nano-dsp + symphonia/cpal/crossterm/image/libc/rtrb
│       ├── NOTES.md                MOVED from nanometers/src/NANOPLAYER_NOTES.md
│       └── src/main.rs             MOVED from nanometers/src/nanoplayer.rs (3 imports re-pointed)
├── docs/adr/0009-ios-renders-natively-in-swiftui.md   NEW (Task 7)
└── xtask/                          unchanged
```

**Critical invariant:** the plugin's cargo package keeps the name `nanometers` (only its directory moves). This preserves the CLAP id `com.willeasp.nanometers` and the AU identity (`aufx`/`Nano`/`Wlsp`) so `auval` and existing DAW projects don't break. `cargo xtask bundle nanometers` is unchanged.

---

## Task 1: Establish a green baseline

No code changes — record the starting state so later breakage is attributable.

**Files:** none.

- [ ] **Step 1: Run the full test suite and record the count**

Run: `cargo test --workspace`
Expected: PASS. Record the totals — on `d3da50b` this is the single `nanometers` crate's tests (~10) plus doctests. Note the exact number printed (`test result: ok. N passed`).

- [ ] **Step 2: Confirm the default and feature builds compile**

Run:
```bash
cargo build
cargo build --features nanoplayer
cargo build --features dev-player
```
Expected: all three finish with `Finished`. (No run needed.)

- [ ] **Step 3: Confirm the cross-compile targets are NOT yet installed (informational)**

Run: `rustup target list --installed | grep -i ios || echo "none"`
Expected: `none` (they get added in Task 6).

No commit (read-only baseline).

---

## Task 2: Carve `crates/nano-dsp` and re-export from the plugin

Create the new crate from the recipe (reconciled to `main`'s types), move the three pure files verbatim, and replace their definitions in the plugin with re-exports. The gate is the whole workspace staying green.

**Files:**
- Create: `crates/nano-dsp/Cargo.toml`
- Create: `crates/nano-dsp/src/lib.rs`
- Create: `crates/nano-dsp/src/waveform/mod.rs`
- Create: `crates/nano-dsp/tests/pure_core_standalone.rs`
- Move: `nanometers/src/loudness.rs` → `crates/nano-dsp/src/loudness.rs`
- Move: `nanometers/src/module/waveform/color.rs` → `crates/nano-dsp/src/waveform/color.rs`
- Move: `nanometers/src/module/waveform/store.rs` → `crates/nano-dsp/src/waveform/store.rs`
- Modify: `Cargo.toml` (workspace members)
- Modify: `nanometers/Cargo.toml` (add nano-dsp dep)
- Modify: `nanometers/src/lib.rs`
- Modify: `nanometers/src/module/mod.rs`
- Modify: `nanometers/src/module/waveform/mod.rs`

- [ ] **Step 1: Create the nano-dsp crate manifest**

Create `crates/nano-dsp/Cargo.toml`:
```toml
[package]
name = "nano-dsp"
version = "0.0.1"
edition.workspace = true
authors.workspace = true
license.workspace = true
repository.workspace = true
description = "Platform-free DSP/domain core for nanometers: envelope store, BS.1770 loudness, spectral color, and the audio→GUI value types. No wgpu, no plugin host, no windowing (ADR 0008)."

[dependencies]
# The only runtime dependency, and a deliberate one: `Measurements` holds the decaying peak as
# lock-free atomics. `atomic_float` is platform-free pure Rust — it does NOT breach ADR 0008's
# "no wgpu / no plugin host / no windowing" rule.
atomic_float.workspace = true

[dev-dependencies]
# Reference BS.1770 implementation, used only as a conformance oracle for the loudness core
# (ADR 0006). Never linked into anything that ships.
ebur128 = "0.1.10"
```

- [ ] **Step 2: Move the three verbatim files with `git mv`**

`main` never edited these since the carve's base, so they move with zero content change.
```bash
mkdir -p crates/nano-dsp/src/waveform
git mv nanometers/src/loudness.rs crates/nano-dsp/src/loudness.rs
git mv nanometers/src/module/waveform/color.rs crates/nano-dsp/src/waveform/color.rs
git mv nanometers/src/module/waveform/store.rs crates/nano-dsp/src/waveform/store.rs
```
Note: `store.rs` line 17 is `use super::color::Filterbank;` — this still resolves, because in nano-dsp `color` is a sibling module under `waveform` (`crates/nano-dsp/src/waveform/{store,color}.rs`), same as before. No edit needed.

- [ ] **Step 3: Create `crates/nano-dsp/src/lib.rs`**

This is the recipe's `lib.rs` **with `FrameContext` reconciled to `main`** (the `frame_dt` field). Create `crates/nano-dsp/src/lib.rs`:
```rust
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

// NOTE: the `ffi` module (C-ABI facade for iOS) is added in Task 5, not here — its file doesn't
// exist yet, and declaring it now would either fail to compile or warn on an undeclared feature.

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
```

- [ ] **Step 4: Create `crates/nano-dsp/src/waveform/mod.rs`**

The scroll-law fns + `pub mod` decls. Create `crates/nano-dsp/src/waveform/mod.rs`:
```rust
//! The Waveform's platform-free pieces (ADRs 0001 / 0002 / 0007).
//!
//! [`store`] owns the base-bin envelope store + sample-anchored column building; [`color`] owns the
//! 3-band filterbank and the band→RGB mapping. This module also holds the pure **scroll control
//! law** — `choose_px_per_frame` and `consume_samples` — the arithmetic that turns clock drift into
//! per-pixel sample counts instead of motion. The wgpu `WaveformModule` in the plugin is a thin
//! wrapper that calls into these.

pub mod color;
pub mod store;

/// Integer pixels the contour moves per render: round the ideal continuous rate
/// (`columns / (window · fps)`) to a whole pixel, at least 1.
pub fn choose_px_per_frame(columns: usize, window_seconds: f64, fps: f64) -> i64 {
    if window_seconds <= 0.0 || fps <= 0.0 {
        return 1;
    }
    ((columns as f64 / (window_seconds * fps)).round() as i64).max(1)
}

/// Samples to consume into this frame's new columns. Pure (no GPU), so the control law is testable.
/// Smoothed arrival rate (`avg_arrival`) nudged by a gentle proportional term toward holding the
/// reservoir at `target`. Clamped ≥ 0 and ≤ `available`.
pub fn consume_samples(
    avg_arrival: f64,
    reservoir: f64,
    target: f64,
    gain: f64,
    available: f64,
) -> f64 {
    let want = avg_arrival + gain * (reservoir - target);
    want.clamp(0.0, available.max(0.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn px_per_frame_rounds_to_a_whole_step() {
        assert_eq!(choose_px_per_frame(1200, 5.0, 120.0), 2);
        assert_eq!(choose_px_per_frame(1200, 5.0, 60.0), 4);
        assert_eq!(choose_px_per_frame(50, 5.0, 120.0), 1);
    }

    #[test]
    fn consume_equals_arrival_at_the_target() {
        assert!((consume_samples(366.0, 1000.0, 1000.0, 0.02, 5000.0) - 366.0).abs() < 1e-9);
    }

    #[test]
    fn consume_speeds_up_when_audio_runs_ahead() {
        let c = consume_samples(366.0, 1500.0, 1000.0, 0.02, 5000.0);
        assert!((c - (366.0 + 0.02 * 500.0)).abs() < 1e-9, "got {c}");
        assert!(c > 366.0 && c < 366.0 + 50.0);
    }

    #[test]
    fn consume_eases_off_when_reservoir_is_low() {
        let c = consume_samples(366.0, 600.0, 1000.0, 0.02, 5000.0);
        assert!((c - (366.0 + 0.02 * -400.0)).abs() < 1e-9, "got {c}");
    }

    #[test]
    fn consume_never_exceeds_available_or_goes_negative() {
        assert_eq!(consume_samples(366.0, 1000.0, 1000.0, 0.02, 100.0), 100.0);
        assert_eq!(consume_samples(10.0, 0.0, 5000.0, 0.02, 5000.0), 0.0);
    }
}
```

- [ ] **Step 5: Create the renderer-independence guard test**

Create `crates/nano-dsp/tests/pure_core_standalone.rs`. This is the recipe's test **with the `FrameContext` literal reconciled** (note the added `frame_dt: 0.0`):
```rust
//! `nano-dsp` is the platform-free domain core (ADR 0008): it must be usable on its own, with no
//! `wgpu`, no `nih_plug`, no `baseview`. This drives the full pure pipeline through ONLY `nano-dsp`'s
//! public API, so it fails to compile the day someone leaks a GUI/plugin dependency into the crate.

use nano_dsp::loudness::{Channels, LoudnessDsp};
use nano_dsp::waveform::color::band_color;
use nano_dsp::waveform::store::{WaveStore, BIN_SECONDS};
use nano_dsp::waveform::{choose_px_per_frame, consume_samples};
use nano_dsp::{FrameContext, Measurements, Rect, StereoFrame};

fn tone(sample_rate: f32, secs: f32) -> Vec<StereoFrame> {
    let n = (sample_rate * secs) as usize;
    (0..n)
        .map(|i| {
            let s = 0.5 * (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / sample_rate).sin();
            [s, s]
        })
        .collect()
}

#[test]
fn pure_pipeline_runs_with_no_platform_deps() {
    const SR: f32 = 48_000.0;
    let frames = tone(SR, 1.0);

    let meas = Measurements::new();
    // NOTE vs the 6e6e538 recipe: FrameContext gained `frame_dt` on main — set it here.
    let ctx = FrameContext { new: &frames, meas: &meas, sample_rate: SR, mono: false, frame_dt: 0.0 };
    assert_eq!(ctx.new.len(), frames.len());
    assert!(!ctx.mono);

    let window_bins = (8.0 / BIN_SECONDS).round() as usize;
    let mut store = WaveStore::new(window_bins, 250.0, 4000.0);
    store.set_sample_rate(ctx.sample_rate);
    for &[l, r] in ctx.new {
        store.push(l, r);
    }
    assert!(store.closed_samples() > 0, "tone should have closed whole bins");
    let col = store.merge_sample_range(0, store.closed_samples() as i64);
    assert!(col.env[0].max > 0.3, "merged column should carry the tone's level");

    let rgb = band_color(col.band_ms);
    assert!(rgb.iter().all(|c| (0.0..=1.0).contains(c)), "color in gamut: {rgb:?}");

    let px = choose_px_per_frame(1200, 5.0, 120.0);
    assert_eq!(px, 2);
    let consumed = consume_samples(366.0, 1000.0, 1000.0, 0.02, 5000.0);
    assert!((consumed - 366.0).abs() < 1e-9);

    let mut loud = LoudnessDsp::new(SR as f64, Channels::Stereo);
    for &[l, r] in ctx.new {
        loud.push_frame(l, r);
    }
    let s = loud.short_term_lufs();
    assert!(s > -30.0 && s < 0.0, "short-term LUFS in a plausible band: {s}");

    let r = Rect { x: 0.0, y: 0.0, w: 800.0, h: 600.0 };
    assert_eq!(r.clip_transform(800.0, 600.0), [1.0, 0.0, 1.0, 0.0]);
}
```

- [ ] **Step 6: Add nano-dsp to the workspace members**

In `Cargo.toml` (workspace root), change line 3:
```toml
members = ["nanometers", "xtask"]
```
to:
```toml
members = ["crates/nano-dsp", "nanometers", "xtask"]
```
(Leave `default-members = ["nanometers"]` for now — it's re-pathed in Task 3.)

- [ ] **Step 7: Add nano-dsp as a dependency of the plugin**

In `nanometers/Cargo.toml`, under `[dependencies]` (after the `nih_plug.workspace = true` line, line 40), add:
```toml
# The platform-free DSP/domain core (ADR 0008). The plugin re-exports its items under their old
# paths so the rest of the crate is unchanged.
nano-dsp = { path = "../crates/nano-dsp" }
```

- [ ] **Step 8: Re-export the moved items from `nanometers/src/lib.rs`**

In `nanometers/src/lib.rs`: delete line 18 (`use module::Measurements;`), and replace the `pub mod loudness;` declaration (lines 26-27) with the re-exports. Replace:
```rust
/// Loudness measurement DSP (ADR 0006). Pure, GUI-side; not yet wired into the Module host.
pub mod loudness;

/// The Module-host contract (ADRs 0002/0003/0004): the `Module` trait, `FrameContext`,
/// `Measurements`, and `Rect`. See `module.rs`.
pub mod module;
```
with:
```rust
/// The platform-free domain core (ADR 0008): loudness, the Waveform's store/color/scroll-law, and
/// the audio→GUI value types. Re-exported under the crate's old paths so the rest of the plugin
/// (and `dev.rs`) keeps using `crate::StereoFrame`, `crate::loudness::…` unchanged.
pub use nano_dsp::loudness;
pub use nano_dsp::{FrameContext, Measurements, Rect, StereoFrame};

/// The Module-host contract (ADRs 0002/0003/0004): the `Module` trait and `EventStatus`. The data
/// types it carries now live in `nano-dsp`.
pub mod module;
```
Then delete the `StereoFrame` definition (lines 71-72):
```rust
/// One interleaved L/R audio frame. Wire format for the audio→GUI ring buffer.
pub type StereoFrame = [f32; 2];
```
(The `use module::Measurements;` deletion is covered: `Measurements` now comes from the `pub use nano_dsp::{… Measurements …}` line, in scope crate-wide as `crate::Measurements` / `Measurements`.)

- [ ] **Step 9: Re-export from `nanometers/src/module/mod.rs` and delete the moved definitions**

In `nanometers/src/module/mod.rs`, replace lines 17-18:
```rust
use crate::StereoFrame;
use atomic_float::AtomicF32;
```
with:
```rust
/// The data types a Module consumes — `Rect`, `Measurements`, `FrameContext`, `StereoFrame` — now
/// live in `nano-dsp` (ADR 0008): platform-free, shared with the TUI and iOS. Re-exported here so
/// the concrete Modules keep referring to `super::{FrameContext, Rect, …}` unchanged. The `Module`
/// trait stays in this crate because its signatures name `wgpu` types.
pub use nano_dsp::{FrameContext, Measurements, Rect, StereoFrame};
```
Then delete the now-moved definitions: the entire `Rect` struct + impl (lines 25-57), the `Measurements` struct + impls (lines 59-80), and the `FrameContext` struct (lines 82-98). Also delete the `#[cfg(test)] mod tests { … }` block at the end (lines 141-164) — those `clip_transform` tests moved to `nano-dsp/src/lib.rs`. Keep `EventStatus`, the `Module` trait, and the `pub mod loudness/oscilloscope/waveform;` declarations.

> Verification anchor: after this edit, `module/mod.rs` should contain `pub use nano_dsp::{…};`, the three `pub mod` lines, `EventStatus`, and the `Module` trait — nothing else.

- [ ] **Step 10: Swap the imports in `nanometers/src/module/waveform/mod.rs`**

In `nanometers/src/module/waveform/mod.rs`: delete lines 18-19:
```rust
pub mod color;
pub mod store;
```
Then replace lines 27-29:
```rust
use super::{EventStatus, FrameContext, Module, Rect};
use color::band_color;
use store::WaveStore;
```
with:
```rust
use super::{EventStatus, FrameContext, Module, Rect};
// The Waveform's GPU-free core now lives in `nano-dsp` (ADR 0008): the base-bin store, the spectral
// color mapping, and the scroll control law. This module is the thin wgpu wrapper over them.
use nano_dsp::waveform::color::band_color;
use nano_dsp::waveform::store::{self, WaveStore};
use nano_dsp::waveform::{choose_px_per_frame, consume_samples};
```
Then delete the two local fn definitions `choose_px_per_frame` (lines 70-78) and `consume_samples` (lines 80-88), and the `#[cfg(test)] mod tests { … }` block at the end of the file containing `px_per_frame_rounds_to_a_whole_step` and the `consume_*` tests (they moved to `nano-dsp`).

> `store::{self, WaveStore}` imports both the module path (for any `store::BaseBin` references elsewhere in the file) and the `WaveStore` type, matching the recipe.

- [ ] **Step 11: Build and test the whole workspace**

Run: `cargo test --workspace`
Expected: PASS. The moved tests now run under `nano-dsp` (loudness + color + store + the two scroll-law tests + the 3 Rect tests + the standalone integration test), and the plugin's remaining tests still pass. Total ≈ 40 (`nano-dsp` unit + `pure_core_standalone` + plugin). If a `FrameContext { … }` literal anywhere fails to compile with "missing field `frame_dt`", that is a leftover literal — add `frame_dt: 0.0` (or the host's real dt). There should be none in this task (the plugin's host literal in `editor.rs` already sets `frame_dt` on `main`).

- [ ] **Step 12: Confirm the feature builds still compile**

Run:
```bash
cargo build --features dev-player
cargo build --features nanoplayer
```
Expected: both `Finished`. (`nanoplayer` still lives in the plugin crate at this point and now reaches the DSP via the plugin's re-exports — it compiles unchanged. It moves out in Task 4.)

- [ ] **Step 13: Commit**

```bash
git add crates/nano-dsp Cargo.toml Cargo.lock nanometers/Cargo.toml \
  nanometers/src/lib.rs nanometers/src/module/mod.rs nanometers/src/module/waveform/mod.rs
git commit -m "Carve nano-dsp from the plugin crate (ADR 0008 step 1, re-derived on main)

Re-derive the 6e6e538 carve onto current main: move loudness/color/store
verbatim into crates/nano-dsp, lift the value types + scroll law down, and
re-export from the plugin under the old paths. Reconciled to main: nano-dsp's
FrameContext carries the frame_dt field main added, and the standalone guard
test sets it. Whole workspace green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Relocate the plugin to `apps/nano-plugin`

Move the plugin crate directory (package name stays `nanometers`) and its `auv2/` AU build under `apps/nano-plugin`, fix the workspace paths, `build.sh`, and the one relative path in the CMake file. Gate: `./build.sh` + `auval`.

**Files:**
- Move: `nanometers/` → `apps/nano-plugin/`
- Move: `auv2/` → `apps/nano-plugin/auv2/`
- Modify: `Cargo.toml` (members + default-members)
- Modify: `apps/nano-plugin/Cargo.toml` (nano-dsp path dep is now one level deeper)
- Modify: `apps/nano-plugin/auv2/CMakeLists.txt` (the `../target` path)
- Modify: `build.sh` (auv2 paths)

- [ ] **Step 1: Move the crate and its AU build directory**

```bash
mkdir -p apps
git mv nanometers apps/nano-plugin
git mv auv2 apps/nano-plugin/auv2
```

- [ ] **Step 2: Fix the workspace member paths**

In `Cargo.toml` (workspace root):
```toml
members = ["crates/nano-dsp", "nanometers", "xtask"]
default-members = ["nanometers"]
```
becomes:
```toml
members = ["crates/nano-dsp", "apps/nano-plugin", "xtask"]
default-members = ["apps/nano-plugin"]
```

- [ ] **Step 3: Fix the nano-dsp path dependency (now one level deeper)**

In `apps/nano-plugin/Cargo.toml`, the dep added in Task 2 was `path = "../crates/nano-dsp"`. From `apps/nano-plugin/` the crate is two levels up. Change:
```toml
nano-dsp = { path = "../crates/nano-dsp" }
```
to:
```toml
nano-dsp = { path = "../../crates/nano-dsp" }
```

- [ ] **Step 4: Fix the CMake path to the prebuilt CLAP**

`target/bundled/nanometers.clap` stays at the workspace root (`target/` is workspace-wide). The CMake file now sits at `apps/nano-plugin/auv2/CMakeLists.txt`, so `${CMAKE_SOURCE_DIR}/../target` no longer reaches the root. In `apps/nano-plugin/auv2/CMakeLists.txt`, change line 39:
```cmake
set(NANOMETERS_CLAP_PATH "${CMAKE_SOURCE_DIR}/../target/bundled/nanometers.clap"
```
to:
```cmake
set(NANOMETERS_CLAP_PATH "${CMAKE_SOURCE_DIR}/../../../target/bundled/nanometers.clap"
```
(`CMAKE_SOURCE_DIR` = `apps/nano-plugin/auv2`; `../../../` = workspace root.)

- [ ] **Step 5: Fix the auv2 paths in `build.sh`**

In `build.sh`, update the three `auv2` references to `apps/nano-plugin/auv2`. Change line 21:
```bash
cmake -B auv2/build -S auv2 -DCMAKE_BUILD_TYPE=Release
```
to:
```bash
cmake -B apps/nano-plugin/auv2/build -S apps/nano-plugin/auv2 -DCMAKE_BUILD_TYPE=Release
```
Change line 27:
```bash
rm -rf auv2/build/nanometers.component
```
to:
```bash
rm -rf apps/nano-plugin/auv2/build/nanometers.component
```
Change line 31:
```bash
COMPONENT=$(find auv2/build -name 'nanometers.component' -type d -maxdepth 4 | head -1)
```
to:
```bash
COMPONENT=$(find apps/nano-plugin/auv2/build -name 'nanometers.component' -type d -maxdepth 4 | head -1)
```
(The `cargo xtask bundle nanometers` line, the `target/bundled/nanometers.clap` copy, and the install paths are unchanged — package name and `target/` location did not move.)

- [ ] **Step 6: Verify the plugin still builds and tests pass**

Run: `cargo test --workspace`
Expected: PASS (same total as Task 2 Step 11). The directory move doesn't change code.

- [ ] **Step 7: Verify the full plugin bundle + AU validation (the regression gate)**

Run: `./build.sh`
Expected: completes through `[4/4] Installing plugins…` and prints the installed paths. Then run:
```bash
killall -9 AudioComponentRegistrar 2>/dev/null; auval -v aufx Nano Wlsp
```
Expected: `AU VALIDATION SUCCEEDED`. (Per CLAUDE.md, if testing GUI in Logic afterward, use a NEW project.)

- [ ] **Step 8: Commit**

```bash
git add -A
git commit -m "Relocate the plugin to apps/nano-plugin (ADR 0008 apps/ layout)

Move the nanometers crate dir and its auv2/ AU build under apps/nano-plugin;
the cargo package name stays 'nanometers' so the CLAP id and AU identity
(aufx/Nano/Wlsp) are unchanged. Fix workspace member paths, the nano-dsp path
dep depth, build.sh's auv2 paths, and the CMake ../target relative path. Only
paths move; ./build.sh + auval green.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Extract the TUI to `apps/nano-tui`

Lift `nanoplayer.rs` out of the plugin crate into its own binary crate that links `nano-dsp` directly, and drop the `nanoplayer` bin/feature/deps from the plugin.

**Files:**
- Create: `apps/nano-tui/Cargo.toml`
- Move: `apps/nano-plugin/src/nanoplayer.rs` → `apps/nano-tui/src/main.rs`
- Move: `apps/nano-plugin/src/NANOPLAYER_NOTES.md` → `apps/nano-tui/NOTES.md`
- Modify: `apps/nano-tui/src/main.rs` (3 import lines + doc comment)
- Modify: `apps/nano-plugin/Cargo.toml` (remove nanoplayer bin/feature/deps)
- Modify: `Cargo.toml` (add member)

- [ ] **Step 1: Create the nano-tui crate manifest**

Create `apps/nano-tui/Cargo.toml`:
```toml
[package]
name = "nano-tui"
version = "0.0.1"
edition.workspace = true
authors.workspace = true
license.workspace = true
repository.workspace = true
description = "Terminal mp3-player + meter that reuses nanometers' DSP core (nano-dsp) over a second, non-GPU frontend. The renderer-independence proof for ADR 0008."

[[bin]]
name = "nano-tui"
path = "src/main.rs"

[dependencies]
# The shared DSP core: LoudnessDsp, Filterbank/band_color, StereoFrame (ADR 0008).
nano-dsp = { path = "../../crates/nano-dsp" }

# Audio→GUI ring (same primitive the plugin uses).
rtrb.workspace = true

# File decode (formats match what the dev-player documents). cpal pinned to nih-plug's version.
symphonia = { version = "0.5", default-features = false, features = [
    "mp3",
    "flac",
    "wav",
    "pcm",
    "aac",
    "isomp4",
] }
cpal = "0.17"

# Terminal control + non-blocking key input.
crossterm = "0.28"

# Embedded cover-art decode (JPEG/PNG) for half-block rendering.
image = { version = "0.25.10", default-features = false, features = ["jpeg", "png"] }

# poll(2) for the timed OSC 11 terminal-background query (theme detect).
libc = "0.2"
```

- [ ] **Step 2: Move the source and notes**

```bash
mkdir -p apps/nano-tui/src
git mv apps/nano-plugin/src/nanoplayer.rs apps/nano-tui/src/main.rs
git mv apps/nano-plugin/src/NANOPLAYER_NOTES.md apps/nano-tui/NOTES.md
```

- [ ] **Step 3: Re-point the three DSP imports in `apps/nano-tui/src/main.rs`**

The file is the lone consumer that leaves the plugin crate, so it can't use the re-exports — point it at `nano-dsp` directly. Names are identical; only the crate root and the `module::` prefix change. Replace lines 44-46:
```rust
use nanometers::StereoFrame;
use nanometers::loudness::{Channels, LoudnessDsp};
use nanometers::module::waveform::color::{Filterbank, band_color};
```
with:
```rust
use nano_dsp::StereoFrame;
use nano_dsp::loudness::{Channels, LoudnessDsp};
use nano_dsp::waveform::color::{Filterbank, band_color};
```

- [ ] **Step 4: Update the module doc comment in `apps/nano-tui/src/main.rs`**

Replace lines 9-10 (which name the old plugin paths):
```rust
//!   * `nanometers::loudness::LoudnessDsp` — momentary/short/integrated LUFS.
//!   * `nanometers::module::waveform::color::{Filterbank, band_color}` — the spectral coloring
```
with:
```rust
//!   * `nano_dsp::loudness::LoudnessDsp` — momentary/short/integrated LUFS.
//!   * `nano_dsp::waveform::color::{Filterbank, band_color}` — the spectral coloring
```

- [ ] **Step 5: Remove the nanoplayer bin, feature, and TUI-only deps from the plugin**

In `apps/nano-plugin/Cargo.toml`:

Delete the nanoplayer `[[bin]]` block (lines 18-23):
```toml
# Throwaway terminal mp3-player + meter prototype (see src/nanoplayer.rs). Gated so a plain
# `cargo build` never pulls in the TUI/audio deps; run with `--features nanoplayer`.
[[bin]]
name = "nanoplayer"
path = "src/nanoplayer.rs"
required-features = ["nanoplayer"]
```

Delete the `nanoplayer` feature (lines 30-32):
```toml
# Terminal player prototype: decode + play a file and render the waveform/LUFS in the terminal,
# reusing the plugin's LoudnessDsp + spectral coloring. Off by default — adds the TUI/audio deps.
nanoplayer = ["dep:symphonia", "dep:cpal", "dep:crossterm", "dep:image", "dep:libc"]
```

Delete the three TUI-only dependencies — `crossterm` (lines 55-56), `image` (lines 58-63), and `libc` (lines 65-66). **Keep `symphonia` and `cpal`** — the `dev-player` feature (`dev.rs`) still uses them.

> After this, the only remaining reference to `symphonia`/`cpal` is the `dev-player` feature, which is correct.

- [ ] **Step 6: Add nano-tui to the workspace members**

In `Cargo.toml` (workspace root):
```toml
members = ["crates/nano-dsp", "apps/nano-plugin", "xtask"]
```
becomes:
```toml
members = ["crates/nano-dsp", "apps/nano-plugin", "apps/nano-tui", "xtask"]
```

- [ ] **Step 7: Build the TUI and confirm the plugin no longer carries it**

Run: `cargo build -p nano-tui`
Expected: `Finished`. (`nano-tui` links `nano-dsp` for the DSP; no dependency on the plugin crate.)

Run: `cargo build -p nanometers --features nanoplayer` 
Expected: FAIL with `error: none of the selected packages contains these features: nanoplayer` (or an unknown-feature error) — the feature is gone, confirming the extraction. Then run `cargo build` (default) and `cargo build --features dev-player`; both Expected: `Finished`.

- [ ] **Step 8: Smoke-run the TUI (optional, manual)**

Run: `cargo run -p nano-tui -- /path/to/song.mp3` (any local audio file)
Expected: a terminal waveform + LUFS meter renders. `q` quits. (Skip if no audio file is handy; the build check in Step 7 is the gate.)

- [ ] **Step 9: Commit**

```bash
git add -A
git commit -m "Extract the TUI to apps/nano-tui, linking nano-dsp (ADR 0008)

Lift nanoplayer.rs out of the plugin crate into its own binary crate that
depends on nano-dsp directly (3 imports re-pointed nanometers:: -> nano_dsp::),
and drop the nanoplayer bin/feature plus the crossterm/image/libc deps from the
plugin. symphonia/cpal stay for the dev-player. The TUI is now a first-class
shell and the carve's renderer-independence proof: same DSP, second frontend.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Add the `nano-dsp` C-ABI FFI facade

A feature-gated (`ffi`) C-ABI surface over the three things the iOS app needs, built as a `staticlib`. TDD: a Rust test exercises each function before the iOS toolchain is involved.

**Files:**
- Modify: `crates/nano-dsp/Cargo.toml` (add `staticlib` crate-type + `ffi` feature)
- Modify: `crates/nano-dsp/src/lib.rs` (declare the gated `ffi` module)
- Create: `crates/nano-dsp/src/ffi.rs`
- Create: `crates/nano-dsp/tests/ffi_abi.rs`

- [ ] **Step 1: Add the staticlib crate-type and the `ffi` feature**

In `crates/nano-dsp/Cargo.toml`, after the `description` line in `[package]`, add:
```toml
[lib]
# `staticlib` is the artifact the iOS .xcframework links; `lib` (rlib) is what the plugin and TUI
# link. cargo builds the rlib for dependents and the .a only when nano-dsp is a top-level target.
crate-type = ["lib", "staticlib"]

[features]
# C-ABI facade for Swift/iOS. Off by default and `#[cfg]`-gating the `ffi` module — so the plugin
# and TUI, which link nano-dsp WITHOUT this feature, never compile the C-ABI code or carry the
# `no_mangle` symbols. Enabled only for the .xcframework build (`--features ffi`).
ffi = []
```

- [ ] **Step 1b: Declare the gated `ffi` module in `lib.rs`**

In `crates/nano-dsp/src/lib.rs`, just after the `pub mod waveform;` block (and the NOTE comment placed there in Task 2 Step 3), add:
```rust
/// C-ABI facade for the iOS app (ADR 0008 / 0009). Gated behind `ffi` so the plugin/TUI never
/// compile it; cbindgen-equivalent header is hand-maintained at `include/nano_dsp.h` (Task 6).
#[cfg(feature = "ffi")]
pub mod ffi;
```
(Replace the "NOTE: the `ffi` module … is added in Task 5" comment from Task 2 with these lines.)

- [ ] **Step 2: Write the failing FFI ABI test**

Create `crates/nano-dsp/tests/ffi_abi.rs`:
```rust
//! Exercises the C-ABI facade through the same calls Swift will make. Gated on the `ffi` feature
//! (run with `cargo test -p nano-dsp --features ffi`).
#![cfg(feature = "ffi")]

use nano_dsp::ffi::{
    nano_dsp_analyze, nano_dsp_integrated_lufs, nano_meter_free, nano_meter_new,
    nano_meter_push, nano_meter_short_term, NanoBin,
};

fn tone(sr: f32, secs: f32) -> Vec<f32> {
    let n = (sr * secs) as usize;
    (0..n)
        .map(|i| 0.5 * (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / sr).sin())
        .collect()
}

#[test]
fn analyze_fills_normalized_bins() {
    const SR: f32 = 48_000.0;
    let pcm = tone(SR, 2.0);
    let n_bins = 150usize;
    let mut out = vec![NanoBin { peak: -1.0, r: -1.0, g: -1.0, b: -1.0 }; n_bins];
    let rc = unsafe { nano_dsp_analyze(pcm.as_ptr(), pcm.len(), SR, n_bins, out.as_mut_ptr()) };
    assert_eq!(rc, 0, "analyze should succeed");
    // Peaks normalized into 0..=1, colors in gamut, and a steady tone has a non-trivial peak.
    assert!(out.iter().all(|b| (0.0..=1.0).contains(&b.peak)), "peaks normalized");
    assert!(out.iter().all(|b| (0.0..=1.0).contains(&b.r)
        && (0.0..=1.0).contains(&b.g)
        && (0.0..=1.0).contains(&b.b)), "colors in gamut");
    assert!(out.iter().any(|b| b.peak > 0.5), "the loud tone should peak near full scale somewhere");
}

#[test]
fn analyze_rejects_null_and_zero_args() {
    let mut out = vec![NanoBin { peak: 0.0, r: 0.0, g: 0.0, b: 0.0 }; 4];
    assert_eq!(unsafe { nano_dsp_analyze(std::ptr::null(), 0, 48_000.0, 4, out.as_mut_ptr()) }, -1);
}

#[test]
fn integrated_lufs_lands_in_a_plausible_band() {
    const SR: f64 = 48_000.0;
    let mono = tone(SR as f32, 4.0);
    let lufs = unsafe { nano_dsp_integrated_lufs(mono.as_ptr(), mono.as_ptr(), mono.len(), SR) };
    assert!(lufs > -30.0 && lufs < 0.0, "integrated LUFS plausible for a -6 dBFS tone: {lufs}");
}

#[test]
fn streaming_meter_roundtrips() {
    const SR: f64 = 48_000.0;
    let mono = tone(SR as f32, 4.0);
    // Interleave the mono tone as stereo L = R.
    let interleaved: Vec<f32> = mono.iter().flat_map(|&s| [s, s]).collect();
    let m = nano_meter_new(SR);
    assert!(!m.is_null());
    unsafe { nano_meter_push(m, interleaved.as_ptr(), mono.len()) };
    let s = unsafe { nano_meter_short_term(m) };
    assert!(s > -30.0 && s < 0.0, "short-term LUFS plausible: {s}");
    unsafe { nano_meter_free(m) };
}
```

- [ ] **Step 3: Run the test to verify it fails to compile**

Run: `cargo test -p nano-dsp --features ffi --test ffi_abi`
Expected: FAIL — `error[E0432]: unresolved import` / `module 'ffi' is private or not found` (the `ffi` module doesn't exist yet).

- [ ] **Step 4: Implement the FFI facade**

Create `crates/nano-dsp/src/ffi.rs`:
```rust
//! C-ABI facade over nano-dsp for the iOS app (ADR 0008 / 0009). Behind the `ffi` feature and built
//! as a `staticlib`; `cbindgen` generates the matching C header from these signatures. Three things
//! cross the boundary — offline analysis, integrated loudness, and a streaming short-term meter —
//! everything else in the app is pure Swift.

use crate::loudness::{Channels, LoudnessDsp};
use crate::waveform::color::band_color;
use crate::waveform::store::{WaveStore, BIN_SECONDS};

/// 3-band filterbank crossovers — must match the plugin/TUI (ADR 0001).
const BAND_LOW_HZ: f32 = 250.0;
const BAND_HIGH_HZ: f32 = 4000.0;

/// One analyzed bin: normalized peak height (0..1) + continuous band color (ADR 0001). Feeds both
/// the overview scrubber and the close-up strip on iOS.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NanoBin {
    pub peak: f32,
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

/// Analyze a whole (mono) track into `n_bins` `(peak, color)` bins. `pcm` points at `len` mono
/// samples; `out` must point at room for `n_bins` `NanoBin`. Peaks are normalized to the track's
/// global max. Returns 0 on success, -1 on a null/zero-argument error.
///
/// # Safety
/// `pcm` must be valid for `len` reads and `out` valid for `n_bins` writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_dsp_analyze(
    pcm: *const f32,
    len: usize,
    sample_rate: f32,
    n_bins: usize,
    out: *mut NanoBin,
) -> i32 {
    if pcm.is_null() || out.is_null() || len == 0 || n_bins == 0 || sample_rate <= 0.0 {
        return -1;
    }
    let samples = unsafe { std::slice::from_raw_parts(pcm, len) };
    let out_slice = unsafe { std::slice::from_raw_parts_mut(out, n_bins) };

    // Size the ring to hold every closed bin for the whole track (offline, one-shot).
    let spb = (sample_rate * BIN_SECONDS).round().max(1.0) as usize;
    let total_bins = len / spb + 1;
    let mut store = WaveStore::new(total_bins.max(n_bins), BAND_LOW_HZ, BAND_HIGH_HZ);
    store.set_sample_rate(sample_rate);
    for &s in samples {
        store.push(s, s); // mono mixdown: L = R (display only)
    }

    let closed = store.closed_samples();
    if closed == 0 {
        // Track shorter than one base bin → all silence.
        for b in out_slice.iter_mut() {
            *b = NanoBin { peak: 0.0, r: 0.0, g: 0.0, b: 0.0 };
        }
        return 0;
    }

    let spc = closed as f64 / n_bins as f64;
    let cols = store.build_columns(n_bins, spc, n_bins as i64 - 1);

    // First pass: raw peak per column (max abs across both channels) + color + global max.
    let mut peaks = Vec::with_capacity(n_bins);
    let mut colors = Vec::with_capacity(n_bins);
    let mut global = 0.0f32;
    for col in &cols {
        let p = col.env[0]
            .max
            .max(col.env[1].max)
            .max(-col.env[0].min)
            .max(-col.env[1].min)
            .max(0.0);
        global = global.max(p);
        peaks.push(p);
        colors.push(band_color(col.band_ms));
    }
    let inv = if global > 0.0 { 1.0 / global } else { 0.0 };

    for (i, b) in out_slice.iter_mut().enumerate() {
        let c = colors[i];
        *b = NanoBin { peak: (peaks[i] * inv).clamp(0.0, 1.0), r: c[0], g: c[1], b: c[2] };
    }
    0
}

/// Integrated (gated) BS.1770 loudness over a stereo track. `l`/`r` each point at `len` samples.
/// Returns the LUFS value, or `f64::NEG_INFINITY` on a null/zero-argument error.
///
/// # Safety
/// `l` and `r` must each be valid for `len` reads.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_dsp_integrated_lufs(
    l: *const f32,
    r: *const f32,
    len: usize,
    sample_rate: f64,
) -> f64 {
    if l.is_null() || r.is_null() || len == 0 || sample_rate <= 0.0 {
        return f64::NEG_INFINITY;
    }
    let ls = unsafe { std::slice::from_raw_parts(l, len) };
    let rs = unsafe { std::slice::from_raw_parts(r, len) };
    let mut dsp = LoudnessDsp::new(sample_rate, Channels::Stereo);
    for i in 0..len {
        dsp.push_frame(ls[i], rs[i]);
    }
    dsp.integrated_lufs()
}

/// Opaque streaming short-term meter. Create with `nano_meter_new`, feed interleaved stereo with
/// `nano_meter_push`, read `nano_meter_short_term` (~10 Hz from a tap), `nano_meter_free` when done.
pub struct NanoMeter {
    dsp: LoudnessDsp,
}

/// Allocate a meter for `sample_rate`. Returns null on an invalid rate. Free with `nano_meter_free`.
#[unsafe(no_mangle)]
pub extern "C" fn nano_meter_new(sample_rate: f64) -> *mut NanoMeter {
    if sample_rate <= 0.0 {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(NanoMeter {
        dsp: LoudnessDsp::new(sample_rate, Channels::Stereo),
    }))
}

/// Feed `frames` interleaved L/R stereo frames (so `interleaved` has `2 * frames` floats).
///
/// # Safety
/// `meter` must be a live handle from `nano_meter_new`; `interleaved` valid for `2 * frames` reads.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_meter_push(
    meter: *mut NanoMeter,
    interleaved: *const f32,
    frames: usize,
) {
    if meter.is_null() || interleaved.is_null() || frames == 0 {
        return;
    }
    let m = unsafe { &mut *meter };
    let buf = unsafe { std::slice::from_raw_parts(interleaved, frames * 2) };
    for f in 0..frames {
        m.dsp.push_frame(buf[2 * f], buf[2 * f + 1]);
    }
}

/// Current short-term (3 s) LUFS. Returns `f64::NEG_INFINITY` on a null handle.
///
/// # Safety
/// `meter` must be a live handle from `nano_meter_new`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_meter_short_term(meter: *const NanoMeter) -> f64 {
    if meter.is_null() {
        return f64::NEG_INFINITY;
    }
    unsafe { (*meter).dsp.short_term_lufs() }
}

/// Free a meter handle. Null is a no-op.
///
/// # Safety
/// `meter` must be a handle from `nano_meter_new` not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_meter_free(meter: *mut NanoMeter) {
    if !meter.is_null() {
        drop(unsafe { Box::from_raw(meter) });
    }
}
```

- [ ] **Step 5: Run the FFI test to verify it passes**

Run: `cargo test -p nano-dsp --features ffi --test ffi_abi`
Expected: PASS (4 tests).

- [ ] **Step 6: Verify the default build still emits no FFI symbols**

Run: `cargo build -p nano-dsp`
Expected: `Finished`. The `ffi` module is `#[cfg(feature = "ffi")]`, so a plain build of nano-dsp (and therefore the plugin/TUI that depend on it without the feature) never compiles the C-ABI code. Also re-run `cargo test --workspace` (without `--features ffi`); Expected: PASS, same total as before.

- [ ] **Step 7: Commit**

```bash
git add crates/nano-dsp/Cargo.toml crates/nano-dsp/src/ffi.rs crates/nano-dsp/tests/ffi_abi.rs Cargo.lock
git commit -m "nano-dsp: add the feature-gated C-ABI FFI facade for iOS

Three boundary functions over the shared DSP — nano_dsp_analyze (peak+color
bins), nano_dsp_integrated_lufs, and the streaming short-term meter
(new/push/short_term/free) — behind the off-by-default 'ffi' feature and a
staticlib crate-type, so the plugin and TUI never emit C symbols. TDD'd via
tests/ffi_abi.rs.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Build `NanoDSP.xcframework` + Swift smoke test

Retire the cross-build risk: provide the C header, prove the C-ABI links and runs from Swift on the host, then assemble the iOS+simulator `.xcframework`.

> Why a hand-authored header, not cbindgen: cbindgen parses source without compiling, so it cannot see `#[cfg(feature = "ffi")]`-gated items unless run through `cargo expand` — which needs the **nightly** toolchain (this repo is pinned to stable 1.89). The ABI here is 2 structs + 6 functions and frozen; a committed header is the robust stable-toolchain choice, and `tests/ffi_abi.rs` pins the Rust side so they can't silently drift. (cbindgen can still regenerate it on nightly via `[parse.expand]` if ever desired.)

**Files:**
- Create: `crates/nano-dsp/include/nano_dsp.h` (committed — the ABI header)
- Create: `crates/nano-dsp/include/module.modulemap` (committed — Clang module map)
- Create: `crates/nano-dsp/build-xcframework.sh`
- Create: `crates/nano-dsp/smoke/smoke.swift`
- (Gitignored: `crates/nano-dsp/NanoDSP.xcframework/`; the iOS `.a` slices live under `target/`, already ignored)

- [ ] **Step 1: Write the C header (mirrors `ffi.rs`)**

Create `crates/nano-dsp/include/nano_dsp.h`:
```c
#ifndef NANO_DSP_H
#define NANO_DSP_H
/* C-ABI for nano-dsp's iOS facade (ADR 0008 / 0009). Mirrors crates/nano-dsp/src/ffi.rs — keep in
 * sync; crates/nano-dsp/tests/ffi_abi.rs pins the Rust side. */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One analyzed bin: normalized peak height (0..1) + continuous band color (ADR 0001). */
typedef struct NanoBin {
    float peak;
    float r;
    float g;
    float b;
} NanoBin;

/* Opaque streaming short-term loudness meter handle. */
typedef struct NanoMeter NanoMeter;

/* Analyze `len` mono samples into `n_bins` (peak, color) bins; `out` holds `n_bins` NanoBin.
 * Peaks are normalized to the track's global max. Returns 0 on success, -1 on bad arguments. */
int32_t nano_dsp_analyze(const float *pcm, size_t len, float sample_rate, size_t n_bins, NanoBin *out);

/* Integrated BS.1770 LUFS over stereo `l`/`r` (`len` samples each). Returns -inf on bad arguments. */
double nano_dsp_integrated_lufs(const float *l, const float *r, size_t len, double sample_rate);

/* Streaming short-term (3 s) meter: create, feed interleaved stereo, read ~10 Hz, free. */
NanoMeter *nano_meter_new(double sample_rate);
void nano_meter_push(NanoMeter *meter, const float *interleaved, size_t frames);
double nano_meter_short_term(const NanoMeter *meter);
void nano_meter_free(NanoMeter *meter);

#ifdef __cplusplus
}
#endif

#endif /* NANO_DSP_H */
```

- [ ] **Step 1b: Write the Clang module map**

Create `crates/nano-dsp/include/module.modulemap`:
```
module NanoDSP {
    header "nano_dsp.h"
    export *
}
```

- [ ] **Step 2: Add the cross-build + assembly script**

Create `crates/nano-dsp/build-xcframework.sh`:
```bash
#!/usr/bin/env bash
# Build nano-dsp's C-ABI staticlib for iOS device + simulator and assemble NanoDSP.xcframework
# (using the committed include/ header + modulemap). Run from anywhere:
#   ./crates/nano-dsp/build-xcframework.sh
set -euo pipefail
cd "$(dirname "$0")/../.."   # workspace root

CRATE_DIR="crates/nano-dsp"
OUT="${CRATE_DIR}/NanoDSP.xcframework"
HEADERS="${CRATE_DIR}/include"   # committed: nano_dsp.h + module.modulemap

echo "==> [1/3] Ensure the iOS targets are installed"
rustup target add aarch64-apple-ios aarch64-apple-ios-sim

echo "==> [2/3] Build the staticlib for device + simulator (arm64), ffi feature on"
cargo build -p nano-dsp --features ffi --release --target aarch64-apple-ios
cargo build -p nano-dsp --features ffi --release --target aarch64-apple-ios-sim

echo "==> [3/3] Assemble the xcframework"
rm -rf "${OUT}"
xcodebuild -create-xcframework \
  -library "target/aarch64-apple-ios/release/libnano_dsp.a"     -headers "${HEADERS}" \
  -library "target/aarch64-apple-ios-sim/release/libnano_dsp.a" -headers "${HEADERS}" \
  -output "${OUT}"

echo "Done: ${OUT}"
```
Then: `chmod +x crates/nano-dsp/build-xcframework.sh`.

> Scope note: device + simulator are both arm64 here (Apple-Silicon dev machines). If an x86_64 simulator slice is ever needed, add `x86_64-apple-ios` and `lipo` it with the arm64 sim lib before `-create-xcframework`. Wiring this into the cargo/Xcode build (vs. this manual script) is the open detail the spec flags — the script is the Phase 0 baseline.

- [ ] **Step 3: Write the Swift host smoke test**

This runs on the dev machine (no simulator needed) by also building a host static lib and linking it. Create `crates/nano-dsp/smoke/smoke.swift`:
```swift
// Host smoke test: link nano-dsp's C-ABI and confirm Swift can call it and get a sane result.
import Foundation

let sr = 48_000.0
let n = Int(sr * 4.0)
var mono = [Float](repeating: 0, count: n)
for i in 0..<n {
    mono[i] = 0.5 * sinf(2.0 * .pi * 1000.0 * Float(i) / Float(sr))
}

// Integrated LUFS over the tone (L = R).
let lufs = nano_dsp_integrated_lufs(mono, mono, n, sr)
print("integrated LUFS = \(lufs)")
precondition(lufs > -30.0 && lufs < 0.0, "integrated LUFS implausible: \(lufs)")

// Analyze into 150 bins.
var bins = [NanoBin](repeating: NanoBin(peak: -1, r: -1, g: -1, b: -1), count: 150)
let rc = nano_dsp_analyze(mono, n, Float(sr), 150, &bins)
precondition(rc == 0, "analyze failed: \(rc)")
precondition(bins.allSatisfy { $0.peak >= 0 && $0.peak <= 1 }, "peaks not normalized")
precondition(bins.contains { $0.peak > 0.5 }, "no loud bin found")

// Streaming meter.
var inter = [Float]()
inter.reserveCapacity(n * 2)
for s in mono { inter.append(s); inter.append(s) }
let m = nano_meter_new(sr)!
nano_meter_push(m, inter, n)
let st = nano_meter_short_term(m)
print("short-term LUFS = \(st)")
precondition(st > -30.0 && st < 0.0, "short-term implausible: \(st)")
nano_meter_free(m)

print("SMOKE OK")
```

- [ ] **Step 4: Run the Swift host smoke test**

Run:
```bash
# Build a host static lib (ffi on), then compile & run the Swift smoke against the committed header.
cargo build -p nano-dsp --features ffi --release
swiftc crates/nano-dsp/smoke/smoke.swift \
  -import-objc-header crates/nano-dsp/include/nano_dsp.h \
  -L target/release -lnano_dsp \
  -o /tmp/nano_smoke
/tmp/nano_smoke
```
Expected: prints `integrated LUFS = …`, `short-term LUFS = …`, and `SMOKE OK` (exit 0). (`cargo build -p nano-dsp --features ffi --release` produces both the rlib and `target/release/libnano_dsp.a`, which `swiftc` links here.)

- [ ] **Step 5: Assemble the iOS xcframework**

Run: `./crates/nano-dsp/build-xcframework.sh`
Expected: ends with `Done: crates/nano-dsp/NanoDSP.xcframework`. Confirm the slices:
```bash
ls crates/nano-dsp/NanoDSP.xcframework
```
Expected: an `Info.plist` plus `ios-arm64` and `ios-arm64-simulator` directories.

- [ ] **Step 6: Gitignore the assembled framework**

Append to `.gitignore` at the repo root (the `include/` header + modulemap are committed; only the assembled framework is a build artifact, and the `.a` slices already live under the ignored `target/`):
```gitignore
# nano-dsp assembled iOS framework (rebuilt by build-xcframework.sh)
/crates/nano-dsp/NanoDSP.xcframework/
```

- [ ] **Step 7: Commit**

```bash
git add crates/nano-dsp/include crates/nano-dsp/build-xcframework.sh \
  crates/nano-dsp/smoke/smoke.swift .gitignore
git commit -m "nano-dsp: C header + NanoDSP.xcframework build + Swift smoke test

Retire the Rust->iOS cross-build risk (spec Risk 1): a committed C header
(include/nano_dsp.h + module.modulemap) mirrors ffi.rs, build-xcframework.sh
cross-builds the staticlib for device + simulator and assembles
NanoDSP.xcframework, and smoke/smoke.swift links the C-ABI on the host and
asserts analyze/integrated/short-term return sane values. Hand-authored header
(cbindgen needs nightly expand for feature-gated code); the assembled framework
is gitignored.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Write ADR 0009

Record the decision the spec pins: iOS renders natively in SwiftUI and links only `nano-dsp`.

**Files:**
- Create: `docs/adr/0009-ios-renders-natively-in-swiftui.md`

- [ ] **Step 1: Write the ADR**

Create `docs/adr/0009-ios-renders-natively-in-swiftui.md`:
```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add docs/adr/0009-ios-renders-natively-in-swiftui.md
git commit -m "docs(adr): 0009 — iOS renders natively in SwiftUI, links only nano-dsp

Record the supersession of ADR 0008's iOS-rendering clause (nano-render +
CAMetalLayer) in favor of native SwiftUI Canvas over a nano-dsp C-ABI facade,
with the Metal escape hatch left open for the close-up if ProMotion forces it.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Done criteria (Phase 0 complete)

- `cargo test --workspace` green; `cargo test -p nano-dsp --features ffi` green.
- `./build.sh` + `auval -v aufx Nano Wlsp` → `AU VALIDATION SUCCEEDED` (plugin identity unchanged).
- `cargo build -p nano-tui` green; the TUI runs and renders.
- `/tmp/nano_smoke` prints `SMOKE OK`; `crates/nano-dsp/NanoDSP.xcframework` has `ios-arm64` + `ios-arm64-simulator` slices.
- `docs/adr/0009-ios-renders-natively-in-swiftui.md` exists.
- Workspace layout matches the File Structure section: `crates/nano-dsp`, `apps/nano-plugin`, `apps/nano-tui`, `xtask`.

The iOS app itself (spec Phases 1–5) is the **next plan** — it links `NanoDSP.xcframework` from here.
