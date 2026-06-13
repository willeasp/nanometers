# Module-host + Waveform + Loudness Modules — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or
> superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`).

**Goal:** Turn nanometers from a single hard-wired glow-line renderer into the multi-Module host the
ADRs describe — a horizontal strip of Modules each owning its DSP + GPU pipelines, fed by one
GUI-side ring drain — and build the Waveform and Loudness Modules into it.

**Architecture:** Audio thread only pushes raw `[L,R]` into the rtrb ring (+ a decaying peak atomic).
The GUI thread (`RenderWindow`, now the *host*) drains the ring once per frame, fans out a
`FrameContext` to every Module, then runs each Module's `prepare` (offscreen passes) and `render`
(composite into its viewport) phases. Layout is a flat left-to-right strip of `width_fraction`
columns persisted in `EditorState`. Per ADRs 0001–0007 + `docs/specs/{waveform,loudness}-module.md`.

**Tech stack:** Rust, nih-plug, raw wgpu 29.0.3, baseview, `wgpu_text` 29.x (new, ADR 0005),
`bytemuck`, `serde`. DSP is hand-rolled (`loudness.rs` already done + ebur128-verified).

**Verification loop (every visible slice):** `cargo run --features dev-player --bin nanometers --
--backend dummy` with `NANO_DEV_FILE` set, then `screencapture -x -o -l <windowid>` (or region) to
confirm the feature renders. Screen-recording permission is confirmed working. Pure logic is
unit-tested with `cargo test -p nanometers`.

---

## Current state (source of truth, read before editing)

- `nanometers/src/lib.rs` — `Nanometers` plugin (audio thread). Pushes `[l,r]` to
  `rtrb::Producer<StereoFrame>`; computes decaying peak per channel → `AtomicF32` in `Shared`.
  `Shared { peak_l, peak_r, samples_rx: Mutex<Consumer> }`. `NanometersParams { editor_state }`.
  Already has `pub mod loudness;`.
- `nanometers/src/editor.rs` — `NanometersEditor` (spawns baseview window), `EditorState { size,
  open }`, `RenderWindow` (owns wgpu device/queue/surface + one `WaveformRenderer` + the
  `display_buffer`/`linear_scratch` ingest). `on_frame` drains→linearizes→uploads→draws. `on_event`
  handles only window resize. `WaveformRenderer` = the 9-layer additive glow line strip (the
  *Oscilloscope*, per glossary — to be replaced by the real Waveform per 0007).
- `nanometers/src/loudness.rs` — `LoudnessDsp` (BS.1770, K-weighting, 100ms bins, M/S/I gated).
  **Done + tested** vs `ebur128` to ~1e-11 LU. Pure, not wired to GPU. Public API: `new(sample_rate:
  f64, channels: Channels)`, `push_frame(l: f32, r: f32)`, `reset()`, `momentary_lufs()`,
  `short_term_lufs()`, `integrated_lufs()` (all return f64 LUFS, `NEG_INFINITY` when empty).
- `nanometers/src/dev.rs` — dev-player (decode file → output + ring). Feature `dev-player`.

---

## Cross-cutting contracts (FREEZE FIRST — Phase A)

All in a new `nanometers/src/module.rs` (declared `pub mod module;` in lib.rs). Modules build
against exactly these. Changing them later is a contract break that ripples to every Module.

```rust
//! The Module-host contract (ADRs 0002/0003/0004). A Module is a self-contained visualization
//! occupying one viewport rectangle; it owns its DSP state and GPU pipeline(s). The host drains
//! the audio ring once per frame and drives every Module through these phases.

use crate::StereoFrame;
use atomic_float::AtomicF32;

/// An INTEGER-aligned physical-pixel rectangle on the surface. The host computes integer column
/// boundaries (see the host-loop block) so x/w/y/h are whole f32s and convert exactly to wgpu's
/// u32 `set_scissor_rect` via `as u32`. The host hands one per column to the Module each frame.
///
/// IMPORTANT — scissor only CLIPS, it does NOT transform. The host calls
/// `set_scissor_rect(viewport)` before each Module's `render`, which only discards fragments
/// outside the rect; it applies NO coordinate transform. Each Module is responsible for mapping
/// its own clip-space / pixel geometry into `viewport`. Use `clip_transform` for the common case
/// of full-surface [-1,1] geometry → this sub-rect.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Rect { pub x: f32, pub y: f32, pub w: f32, pub h: f32 }

impl Rect {
    /// Map full-surface clip space [-1,1] into this sub-rect, given the surface size in physical
    /// px. Returns (scale_x, offset_x, scale_y, offset_y) for `ndc' = scale * ndc + offset`. Y
    /// flips (pixel-y grows down, NDC-y grows up). A full-surface rect → identity (1,0,1,0).
    /// Unit-tested (TDD). Modules upload this in a uniform; the vertex shader applies it.
    pub fn clip_transform(&self, surface_w: f32, surface_h: f32) -> [f32; 4] {
        let sx = self.w / surface_w;
        let ox = (2.0 * self.x + self.w) / surface_w - 1.0;
        let sy = self.h / surface_h;
        let oy = 1.0 - (2.0 * self.y + self.h) / surface_h;
        [sx, ox, sy, oy]
    }
}

/// Cheap scalars the audio thread computes because they're broadly useful (0002). NOT where
/// Module measurements live — Modules derive their own from `new`. Stays tiny by design.
pub struct Measurements { pub peak_l: AtomicF32, pub peak_r: AtomicF32 }

/// Fanned out to every Module each frame (0002). `new` is this frame's freshly drained samples,
/// oldest→newest. `sample_rate`/`mono` are host metadata read once at `initialize` time, constant
/// per stream; `sample_rate == 0.0` means unknown (Modules idle).
pub struct FrameContext<'a> {
    pub new: &'a [StereoFrame],
    pub meas: &'a Measurements,
    pub sample_rate: f32,
    pub mono: bool,
}

/// What a Module reports back to the host's pointer-grab state machine (0004).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum EventStatus { Captured, Ignored }

pub trait Module {
    /// Phase 1 — fold this frame's new samples into GUI-side state; upload to owned GPU buffers.
    fn update(&mut self, ctx: &FrameContext, queue: &wgpu::Queue);

    /// Phase 2a (optional) — encode any OWN offscreen passes (e.g. the Waveform's MSAA contour
    /// target, 0007) into `encoder` before the host's shared single-sample pass opens. Default
    /// no-op; Modules that draw straight into the shared pass (Loudness, the wrapped Oscilloscope)
    /// don't override it. This elaborates 0002's two-phase model: the offscreen draw is part of
    /// "render" but needs encoder access, which the shared `RenderPass` can't give. Reconcile
    /// spec §8 / ADR 0002 trait block to match once built (Phase F).
    fn prepare(
        &mut self,
        _device: &wgpu::Device,
        _queue: &wgpu::Queue,
        _encoder: &mut wgpu::CommandEncoder,
        _viewport: Rect,
    ) {}

    /// Phase 2b — draw (or composite the resolved offscreen result) into `viewport` within the
    /// host's shared pass. The host has already called `set_scissor_rect(viewport)` (clip only —
    /// see `Rect`). `render` MUST set every pipeline-state it depends on (pipeline, all bind
    /// groups, vertex/index buffers) and must NOT rely on state left by a prior Module. The host
    /// guarantees only the scissor rect and the cleared/loaded attachment; render order is
    /// otherwise arbitrary, so each Module's draw must be self-contained.
    fn render(&mut self, rpass: &mut wgpu::RenderPass, viewport: Rect);

    /// Pointer/keyboard inside this Module's viewport, in COLUMN-LOCAL coords (0004). Return
    /// `Ignored` for anything not consumed so the host can turn a body-press into a reorder.
    fn on_event(&mut self, event: &baseview::Event, viewport: Rect) -> EventStatus;

    /// Opaque per-instance config persistence (0003). Host stores the bytes, never reads them.
    fn save_config(&self) -> Vec<u8>;
    fn load_config(&mut self, bytes: &[u8]);
}
```

**Host loop shape** (`RenderWindow::on_frame`, replacing the single-renderer body):

```text
drain ring once → self.new_samples (reused Vec<StereoFrame>, cleared each frame)
ctx = FrameContext { new: &self.new_samples, meas: &self.shared.meas, sample_rate, mono }
for m in &mut modules: m.update(&ctx, &queue)
encoder = create_command_encoder()
for (m, vp) in modules.zip(viewports): m.prepare(&device, &queue, &mut encoder, vp)   // offscreen
{ shared pass: clear CLEAR_COLOR, single-sample
    for (m, vp) in modules.zip(viewports): rpass.set_scissor_rect(vp); m.render(&mut rpass, vp)
}
queue.submit([encoder.finish()]); frame.present()
```

`viewports` come from layout (Phase B), computed as INTEGER pixel boundaries so columns tile the
surface with no gaps/overlaps and convert exactly to wgpu's u32 `set_scissor_rect`:
`b[0]=0; b[i+1]=floor(Σ fractions[..=i] × W); b[last]=W` (force the last boundary to exactly W so
widths sum to W). Column i is `Rect { x: b[i], y: 0, w: b[i+1]-b[i], h: H }` (integer-valued f32).
Until Phase B lands, Phase A uses a single full-surface viewport `Rect{0,0,W,H}` → `clip_transform`
identity, so the wrapped Oscilloscope renders exactly as today.

---

## Phase A — Module host foundation (Task #1)

**Goal:** the trait + context exist, the host drains-and-fans-out, and the EXISTING glow line still
renders — now as a `Module`. No behavior change on screen; pure rearchitecture.

**Files:**
- Create: `nanometers/src/module.rs` (the contracts above).
- Create: `nanometers/src/modules/oscilloscope.rs` (move `WaveformRenderer` here, impl `Module`).
- Modify: `nanometers/src/lib.rs` (add `pub mod module;`, `pub mod modules;`; replace the two loose
  peak atomics in `Shared` with `Measurements`).
- Modify: `nanometers/src/editor.rs` (RenderWindow holds `Vec<Box<dyn Module>>`; ingest moves into
  the host drain; `on_frame` runs the loop above).

- [ ] **A1 — Add the contracts module.** Create `module.rs` exactly as above. Add `pub mod module;`
  to `lib.rs`. `cargo build -p nanometers` → compiles (unused-warning OK).
- [ ] **A1b — Reconcile the contract docs AT FREEZE (not in F).** The trait *is* the contract, and
  ADR 0002 + spec §8 currently list a strictly two-phase trait. The moment `module.rs` exists, add
  the `prepare` phase to ADR 0002's trait block and `waveform-module.md` §8, framed as the
  offscreen-pass elaboration ADR 0007 forces (own MSAA target, host pass stays single-sample). This
  makes "deliberate documented elaboration, not drift" true at freeze. (F3 keeps only a final
  verify.) Per CLAUDE.md: code is the source of truth; the doc follows it.
- [ ] **A1c — TDD `Rect::clip_transform`.** Failing test first in `module.rs` tests: full-surface
  `Rect{0,0,800,600}` → `[1,0,1,0]`; right half `Rect{400,0,400,600}` → `[0.5,0.5,1,0]`; bottom half
  `Rect{0,300,800,300}` → `[1,0,0.5,-0.5]`. Watch fail → implement (already drafted above) → pass.
- [ ] **A2 — Replace loose peaks with `Measurements`.** In `lib.rs`, change `Shared` to hold
  `meas: Measurements` (move `peak_l`/`peak_r` inside). Update `process` to write
  `self.shared.meas.peak_l/_r`. `cargo build` green.
- [ ] **A3 — Move the glow renderer into an Oscilloscope Module.** Create `modules/oscilloscope.rs`;
  move `WaveformRenderer` + `WAVEFORM_WGSL` there verbatim, rename to `OscilloscopeModule`. It owns
  its own `display_buffer`/`linear_scratch`/`write_head` (ingest becomes per-Module: `update` folds
  `ctx.new` into the ring, uploads to its vertex buffers). `render` does the two-channel draw.
  `prepare` default. `on_event` → `Ignored`. `save_config`/`load_config` → empty `Vec`/no-op for now.
- [ ] **A4 — Make RenderWindow the host.** Hold `modules: Vec<Box<dyn Module>>` (init with one
  `OscilloscopeModule`), `new_samples: Vec<StereoFrame>`, `sample_rate`, `mono`. `drain_audio` fills
  `new_samples` (cleared first). `on_frame` runs the host loop (single full-surface viewport for
  now). Delete the old per-RenderWindow `display_buffer`/`linear_scratch`/waveform fields.
- [ ] **A5 — Pass host metadata.** Thread `sample_rate`/`mono` from `initialize` to the editor.
  Cleanest: add `sample_rate: AtomicF32` + `mono: AtomicBool` to `Shared`, set in `initialize`,
  read into `FrameContext` each frame. (`mono` = audio layout main_input_channels == 1.)
- [ ] **A6 — Build + verify in GUI.** `cargo build -p nanometers`. Then run dev-player and
  screencapture; confirm the cyan glow line still renders L over R exactly as before. Commit:
  `refactor: introduce Module trait + host drain/fan-out; wrap glow line as Oscilloscope Module`.

**Note on RT-safety:** `new_samples: Vec` is GUI-side only — never touched by the audio thread —
so growth/alloc there is fine. The audio thread path is unchanged (still wait-free `push`).

---

## Phase B — Horizontal-strip layout + viewports + persistence (Task #2)

**Goal:** `EditorState` persists a layout of columns; the host renders each Module into its
fractional viewport; default layout is Waveform + Loudness (use Oscilloscope placeholders until C/D
land, so this phase is independently verifiable as two side-by-side Module columns).

**Files:**
- Modify: `nanometers/src/editor.rs` (`EditorState` gains `layout`; viewport math; host iterates).
- Create: `nanometers/src/layout.rs` (pure geometry: fractions→rects, x→column index, gutter test).

- [ ] **B1 — Layout types + serde.** In `layout.rs`. `module_type` is a **`String`**, NOT an enum:
  a bare enum fails the WHOLE `editor-state` deserialize on an unknown variant (confirmed serde
  1.0.228) — a future build's Spectrogram column would wipe a saved project's layout *and* window
  size in an older build. A String resolves to a constructor at build time; an unknown type maps to
  an `UnknownModule` placeholder that renders nothing AND preserves the original type string + config
  bytes so re-save is lossless.
  ```rust
  pub mod module_type { // canonical type tags — consts, not stringly-typed at call sites
      pub const OSCILLOSCOPE: &str = "oscilloscope";
      pub const WAVEFORM: &str = "waveform";
      pub const LOUDNESS: &str = "loudness";
  }
  #[derive(Clone, Serialize, Deserialize)]
  pub struct Column { pub instance_id: u64, pub module_type: String,
                      pub width_fraction: f32, pub config: Vec<u8> }
  ```
  Default layout helper: `WAVEFORM` + `LOUDNESS`, each `width_fraction 0.5`, ids 0 and 1, empty
  config. **instance_id allocator:** the host (`RenderWindow`) owns a monotonic `next_id: u64`,
  seeded `max(persisted ids) + 1` when built from a loaded layout (0 for a fresh default), so a
  later "add Module" can't collide with persisted ids (E2's PointerGrab resolves the grabbed column
  by `instance_id`). Invariant: ids are unique within a layout.
- [ ] **B2 — Pure viewport math + test (TDD).** `fn viewports(cols: &[Column], surface: (f32,f32))
  -> Vec<Rect>` — x accumulates `floor(frac·W)`, widths sum to exactly W (last column absorbs
  rounding). Write the failing test first (2 columns @0.5 over W=800 → `[{0,0,400,H},{400,0,400,H}]`;
  3 uneven columns sum to W). Run → fail → implement → pass.
- [ ] **B3 — Persist layout.** Add `layout` to `EditorState` behind a `Mutex<Vec<Column>>` (GUI
  mutates on reorder/resize; serde with `#[serde(with = "...")]` over the Mutex, or a manual impl).
  Keep `size`/`open`. **`PersistentField::set` MUST replace the layout** — the current impl
  (editor.rs:74-76) copies only `size`, so nih-plug's derive deserializes into a throwaway temporary
  and the persisted layout is silently dropped; every reopen would revert to default and ALL Module
  config (Column.config bytes ride this same path) would never persist. New `set`:
  `*self.layout.lock().unwrap() = new_value.layout.into_inner().unwrap(); self.size.store(...)`.
  Rename `from_size` → `from_defaults` (size + default layout). **TDD the round-trip:** serialize an
  EditorState with a 2-column layout (distinct ids, fractions, config bytes), run it through
  `set`, assert the layout CONTENTS survive (ids, fractions, AND config bytes) — not just that
  deserialize succeeded. Also assert a `width_fraction` of `NaN`/`inf` is rejected before save (it
  serializes to JSON `null` and fails the whole load — clamp finite>0 in Phase E reflow).
- [ ] **B4 — Host renders N modules into viewports.** RenderWindow builds its `modules` Vec from the
  persisted layout (map `ModuleType` → constructor; unknown→Oscilloscope placeholder for now).
  `on_frame` zips `modules` with `viewports(&layout, surface)`, `set_scissor_rect` per module.
- [ ] **B5 — Build + verify in GUI.** Two side-by-side Module columns, each rendering column-local
  (give the placeholder Oscilloscope a `clip_transform` uniform so it maps into its viewport, not a
  cropped full-width wave — see the wgpu review's scissor finding). Screencapture confirms the split
  and that each wave fills its own column. Commit:
  `feat(layout): horizontal-strip columns with fractional viewports + persistence`.

---

## Phase C — Waveform Module (Task #3) — spec §9 milestones M1–M5

**Files:**
- Create: `nanometers/src/modules/waveform/mod.rs` (the Module), `store.rs` (base-bin store),
  `color.rs` (filterbank + mapping), `contour.wgsl` (or inline WGSL).

- [ ] **C1 — Base-bin store + associative merge (TDD).** `store.rs` (type name matches spec §2):
  ```rust
  #[derive(Clone, Copy)]
  pub struct ChannelEnvelope { pub min: f32, pub max: f32, pub mean_square: f32 }
  pub struct BaseBin { pub env: [ChannelEnvelope; 2], pub band_ms: [f32; 3] }  // bands shared (mono)
  ```
  Ring of `BaseBin` at 0.5 ms (`samples_per_bin = round(sample_rate * 0.0005)`). Test: merging two
  bins is associative — `min`=min, `max`=max, `mean_square`=sample-weighted average, `band_ms`
  likewise; `merge(merge(a,b),c) == merge(a,merge(b,c))`. Test draw-merge of N base bins → M columns
  conserves global min/max. Red→green.
- [ ] **C2 — M1: mono monochrome scrolling contour.** Module folds `ctx.new` into the store (mono
  sum for now), merges visible bins → columns, builds a per-channel triangle strip (max-curve top,
  min-curve bottom) in clip space, uploads, draws. Newest column at right edge. Fixed
  `window_seconds` (default ~5). Verify in GUI on the dev-player: a scrolling filled envelope.
  Commit.
- [ ] **C3 — M2: stereo halves + outline + offscreen MSAA.** Store min/max/ms per channel; L fills
  top half of viewport, R bottom. Outline = brighter line-strip over the silhouette (config toggle,
  default on). AA: render the contour to the Module's OWN offscreen MSAA texture in `prepare`,
  resolve, then `render` composites the resolved texture into the viewport (single-sample shared
  pass). Verify: smooth (non-staircased) edges, both channels. Commit.
- [ ] **C4 — M3: 3-band filterbank color (TDD + GUI tuning).** `color.rs`: 3 biquad crossovers on
  the mono sum (`band_low_hz≈250`, `band_high_hz≈4000`), per-sample `band²` → `band_ms`. Mapping:
  normalize 3 band mean-squares to a balance; dominant band → hue (low=R, mid=G, high=B);
  imbalance → saturation; balanced → white. Unit tests: bass-only→red, treble-only→blue,
  flat→white, bass+air→**white not magenta** (the 0001 trap). Carry one color/column on strip
  vertices, interpolate along time. Tune live on the dev-player. Commit.
- [ ] **C5 — M4 + M5 (hover + config) — deferred to Phases E/F.** Hover dB readout needs wgpu_text
  (Phase D brings it) + input routing (Phase E). Opaque config blob lands in Phase F. Leave TODO
  markers wired to those phases.

---

## Phase D — Loudness Module (Task #4)

**Files:**
- Modify: `nanometers/Cargo.toml` (+`wgpu_text = "29"` matching wgpu 29.0.3; verify it resolves
  against the locked wgpu). Add an OFL font under `nanometers/assets/` (e.g. an Inter or
  JetBrains Mono `.ttf`, tabular figures preferred per 0005), embed via `include_bytes!`.
- Create: `nanometers/src/modules/loudness.rs` (the Module wrapping `LoudnessDsp`).

- [ ] **D1 — Add wgpu_text + font; smoke-render text.** Add the dep + embed the font. Verify it
  resolves: `cargo build -p nanometers`. A throwaway "‐14.0 LUFS" drawn in a viewport, screencaptured.
- [ ] **D2 — Wrap LoudnessDsp in a Module.** Construct `LoudnessDsp::new(sample_rate, channels)`
  lazily once `ctx.sample_rate > 0` (idle while 0, per spec); `channels = if ctx.mono {Mono} else
  {Stereo}`. Rebuild on sample-rate change. `update` calls `push_frame(l,r)` for each `ctx.new`.
  `on_event`/config stubbed (reset + target come in E/F). Unit test: feed a −23 LUFS sine through
  the Module's update path, assert `integrated_lufs() ≈ −23` (reuses the loudness.rs oracle pattern).
- [ ] **D3 — Numeric readouts.** `render` draws M / S / I as `wgpu_text` sections inside the
  viewport, clipped with `set_scissor_rect`; format `NEG_INFINITY` as `-∞`/`--`. Verify in GUI:
  live M/S/I numbers tracking the dev-player song. Commit.
- [ ] **D4 — Bars + LU scale.** Three vertical bars (M/S/I) mapped from LUFS to bar height around a
  default Target (−14 LUFS, EBU-ish scale); pure LUFS→fraction mapping unit-tested. Verify in GUI.
  Commit.

---

## Phase E — Input routing: host PointerGrab (Task #5) — BUILT

> Built 2026-06-13. The detailed, as-built plan (with the render-side-router correction and the
> grill's scope decisions) is [`2026-06-13-phase-e-input.md`](2026-06-13-phase-e-input.md); ADR 0004
> carries the amendment. The router moved to the RENDER thread (modules + layout live there since
> ADR 0008) — `on_event` is just a forwarder over the `WindowMsg` channel. Sketch below kept for
> history; the paths (`nanometers/src/…`) predate the workspace split.

- [x] **E1 — Pure hit-testing + reorder + sanitize (TDD).** `column_index_at`, `resize_boundary_at`
  (flex|flex only — fixed columns aren't user-draggable), `reorder_target` + `apply_reorder`, and
  `sanitize_layout` (a NaN fraction serializes to JSON `null` and fails the whole load). In
  `layout.rs`. (Reflow carries provisional `Column`s, not bare fractions — fixed columns kept px.)
- [x] **E2 — PointerGrab state machine** (render-side, `input.rs`). `None` / `LayoutReorder` /
  `Module`; press decides once; live-reflow reorder commits on release. `LayoutResize` **deferred to
  Phase F** — no draggable flex|flex boundary exists until multi-instance can add a second flex column.
- [x] **E3 — Module interactions.** Loudness reset on an I-caption click → `LoudnessDsp::reset()` +
  `Captured`. Waveform hover records the peak dB under the cursor (routing proven); the on-screen dB
  **text is deferred** to a follow-up (it needs a `wgpu_text` brush in the waveform module).

---

## Phase F — Opaque config + multi-instance + doc reconciliation (Task #6)

- [ ] **F1 — Module config blobs.** Define each Module's config struct (Waveform: `window_seconds`,
  `outline_enabled`, `band_low_hz`, `band_high_hz`, `color_white_strength`; Loudness: `target`,
  `scale`, `prominent_scale`). `save_config` serializes (bincode/serde-json bytes); `load_config`
  applies. Host persists the bytes in each `Column.config` through the layout serde. Round-trip test.
- [ ] **F2 — Multi-instance.** Confirm two `Waveform` columns with different `window_seconds`
  render independently (own store/filterbank/config). Add to default layout temporarily to verify,
  then restore default. Screencapture two different zooms.
- [ ] **F3 — Reconcile docs to built code.** Update `docs/specs/waveform-module.md` §8 and ADR 0002's
  trait block to include the `prepare` phase (the offscreen-pass elaboration). Per CLAUDE.md "code
  is the source of truth — fix the doc to match." Commit `docs: reconcile Module trait with built
  prepare phase`.
- [ ] **F4 — Final adversarial review + GUI pass.** Review workflow over the full diff
  (RT-safety, wgpu correctness, layout/persistence, BS.1770 channel mode). Full GUI screencapture of
  the default Waveform + Loudness layout on the dev-player song.

---

## Self-review (run against the spec)

- **0001 coloring** → C4 (filterbank + balance→white, with the bass+air→white test). ✓
- **0002 data flow** → A (FrameContext/Measurements/trait/host drain-and-fan-out, GUI-side reduce). ✓
- **0003 layout/config** → B (strip + fractional viewports + persist) + F (opaque config). ✓
- **0004 input** → E (PointerGrab, Captured/Ignored, live reflow). ✓
- **0005 text** → D (wgpu_text + embedded OFL font, per-Module brush, scissor-clipped). ✓
- **0006 loudness DSP** → already done; D wraps it. ✓
- **0007 contour/AA** → C2/C3 (min/max contour, scroll, outline, per-Module offscreen MSAA;
  GLOW_LAYERS deleted when the Oscilloscope placeholder is replaced by Waveform in the default). ✓
- **Type consistency:** `Rect`, `FrameContext`, `Module`, `EventStatus`, `ModuleType`, `Column`,
  `ChannelEnv`/`BaseBin`, `PointerGrab` are each defined once and reused verbatim above.
- **Known gap, reconciled at FREEZE (A1b), not F:** the spec §8 trait omits `prepare`; we add it
  for the offscreen pass and update ADR 0002 + spec §8 the moment `module.rs` exists (deliberate,
  documented elaboration ADR 0007 forces, not drift). F3 keeps only a final verify.

## Phase-local review catches (fold in when the phase arrives)

From the contract-review fan-out (2026-05-30). None block coding; each is a precise, phase-local fix:

- **A5 / dev — dev-player sample rate.** `dev::spawn` feeds the ring at the *file's* native rate,
  while `Shared.sample_rate` is set from `buffer_config` (the dummy backend, 48 kHz). So on-screen
  DSP-timing checks can be subtly off. Fix: pass `Arc<Shared>` (or just the `AtomicF32`) into
  `dev::spawn` and store the decoded file rate into `Shared.sample_rate` for dev builds. Unit tests
  bypass this and stay authoritative. Also derive `mono` from `main_input_channels == 1` at
  `initialize`, never hardcoded.
- **C3 — offscreen MSAA target caching.** Cache the MSAA texture/view + resolved single-sample
  texture + composite bind group keyed on the rounded `(w,h)` of the viewport; recreate only on
  change; guard `w>=1 && h>=1` (a collapsed column mid-reorder yields ~0). Round `Rect` f32→u32 the
  same way the host rounds for scissor, to avoid seams.
- **D — Loudness wiring.** Cast `ctx.sample_rate` (f32) → f64 once at construction for
  `LoudnessDsp::new`; map `ctx.mono` → `Channels::{Mono,Stereo}`. **TDD the +3 LU trap (D2):** a
  mono `FrameContext` path must measure a single channel, not L+R. Construct the `wgpu_text` brush
  with the host's surface format + single-sample (matching the shared pass) or it's a draw-time
  validation error. Loudness leaves `prepare` as the default no-op (text self-AAs, 0005).
- **E — non-finite fraction guard.** In reflow/reorder math, clamp every `width_fraction` finite and
  `> 0` (divide-by-collapsed-column yields NaN → serializes to JSON `null` → fails the whole
  editor-state load on reopen). The "fractions sum to 1" test gains "and each is finite > 0".
- **D / wgpu_text — pipeline compat.** The brush's color-target format must equal the surface
  format and its sample count must be 1 (the shared pass). Note this in the loudness spec when wiring.
