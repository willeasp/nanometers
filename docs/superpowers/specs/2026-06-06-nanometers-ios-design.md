# Nanometers iOS — design

**Date:** 2026-06-06
**Status:** approved (brainstorm) — next step is an implementation plan
**Source material:** `~/Downloads/design_handoff_nanometers/` (locked hi-fi handoff, 5 docs + React/HTML prototype + 4 reference screenshots), and `docs/adr/0008-workspace-crate-split-cross-platform.md`.

## What we're building

A native iOS audio player — **Nanometers iOS** — that plays local audio (cloud sources
deferred, see Scope) through one unified library with on-device playlists. Its soul features,
carried over from the Nanometers plugin: a pair of **frequency-colored waveforms** (a DJ-style
*close-up* strip scrolling past a fixed playhead, plus a full-song *overview* scrubber) and a
short-term **LUFS** readout (BS.1770). Dark, amber accent (`#EFA869`), "Pro" personality,
iOS liquid-glass surfaces. The design is **locked and high-fidelity** — tokens, type, spacing,
radii, and motion in the handoff are final and recreated pixel-accurately.

The handoff is the source of truth for *look and behavior*. This document is the source of truth
for the *native architecture* — the decisions the handoff deliberately left to the implementer,
plus the few places we diverge from it or from ADR 0008, recorded explicitly below.

## Decisions (the forks we resolved)

1. **Native SwiftUI, link `nano-dsp`, draw in `Canvas`.** Build the UI, playback, and *all*
   waveform rendering natively in SwiftUI. Link the Rust **`nano-dsp`** crate (band-split +
   BS.1770) via a C-ABI staticlib. Do **not** reuse `nano-render` (the wgpu renderers) on iOS.
2. **`nano-dsp`'s role on iOS is the pure math only** — `(peak, color)` binning and BS.1770
   loudness. The **scroll control law is deliberately not ported**: the reservoir / time-cursor /
   resync machinery exists to reconcile live, bursty audio-block arrival against an independent
   render clock (the *plugin's* problem). A file player owns the whole decoded file and a
   sample-accurate `AVAudioPlayerNode` clock, so the close-up is a direct window into precomputed
   bins — no drift loop needed.
3. **Monorepo, restructured to ADR 0008's end-state layout.** The app lives at `apps/nano-ios`.
   Phase 0 both **carves `nano-dsp`** (ADR 0008 step 1) and **relocates the plugin** to
   `apps/nano-plugin`, so shells are consistently under `apps/`.
4. **Scope: playable core + the full close-up/short-term-LUFS soul features, local files only.**
   Cloud/multi-source is deferred to a v2 plan (see Scope).

### This supersedes part of ADR 0008 — and that gets recorded

The relevant ADR is **`0008-workspace-crate-split-cross-platform.md`** (referenced as "ADR 0008"
throughout). It states the iOS app is "a `staticlib` linking `nano-render` + `nano-dsp` … wrapped
by an Xcode project drawing into a `CAMetalLayer`." Decisions 1–2 above deliberately drop the
`nano-render`/Metal reuse for iOS in favor of native SwiftUI `Canvas` rendering. Per CLAUDE.md,
an accepted ADR is not something to silently contradict. **Phase 0 includes writing a new ADR**
— `docs/adr/0009-ios-renders-natively-in-swiftui.md` — superseding that clause and recording:
*iOS renders natively in SwiftUI `Canvas` and links only `nano-dsp`; `nano-render` reuse on iOS is
dropped, re-openable only if profiling forces the close-up to Metal.* The rationale is captured
below under "Why native rendering, not nano-render."

> Repo-hygiene note: `main` currently carries **two** ADRs numbered 0008 — the workspace-split one
> above and an unrelated `0008-render-thread-swapchain-paced.md` from concurrent editor work. They
> collide on number only; this spec depends solely on the workspace-split one. The iOS ADR takes
> the next free number, **0009**, rather than adding to the collision. Renumbering the duplicate is
> a separate decision for the maintainer, out of scope here.

## Workspace shape

```
nanometers/                  (repo root — cargo workspace)
├── crates/
│   └── nano-dsp/            NEW: pure domain (WaveStore/BaseBin, BIN_SECONDS, band_color,
│        └── ffi/                 loudness/BS.1770, StereoFrame) + a C-ABI facade for iOS.
│                                 nano-render / nano-audio remain future ADR-0008 steps — NOT this plan.
├── apps/
│   ├── nano-plugin/         MOVED from ./nanometers (nih_plug Plugin + baseview editor host).
│   │                              auv2/ (clap-wrapper AU build) travels with it.
│   └── nano-ios/            NEW: SwiftUI app + the nano-dsp .xcframework.
├── xtask/                   stays at root — workspace build shim.
└── build.sh                 paths updated for the relocation.
```

`crates/` (libraries) vs `apps/` (shells) is our convention; ADR 0008 names the crates but does
not mandate a folder. The plugin's regression gate (`./build.sh` + `auval -v`) is unchanged in
*behavior*; only paths move.

## The `nano-dsp` FFI seam

Three things cross the Rust↔Swift boundary. Everything else in the app is pure Swift. Exact
byte-packing and naming are an implementation-plan detail; these are the shapes:

1. **Offline analysis** — `analyze(pcm, len, sampleRate, nBins) → [(peak, color)]`. One pass per
   file (built on `WaveStore` + `band_color`), feeding *both* waveforms; the result is cached.
2. **Integrated loudness** — `integratedLUFS(l, r, len, sampleRate) → Double`, from the same
   decode pass. This is the stable per-track number shown in list rows and the context menu.
3. **Streaming short-term meter** — `new(sampleRate)` / `push(frames)` / `shortTerm() → Double` /
   `free()`. The *only* live DSP path, fed by an `AVAudioEngine` main-mixer tap, read ~10 Hz for
   the Now Playing "S" badge.

Packaging: a Rust `staticlib` + a `cbindgen`-generated C header, built for `aarch64-apple-ios`
and `aarch64-apple-ios-sim`, assembled into a single `.xcframework` the Swift project links.

**Color reconciliation:** the handoff specifies 4 discrete band hexes
(`#FF6B6B`/`#57D986`/`#6AA6FF`/`#EEF1F6`); `nano-dsp`'s `band_color` produces a richer
*continuous* desaturated hue (ADR 0001). We use `nano-dsp`'s continuous color (the actual
decision, byte-identical to the plugin), treating the four hexes as anchor points — which is why
`analyze` returns a color rather than a band index.

## Swift app architecture (`apps/nano-ios`)

Follows the handoff's architecture-at-a-glance. Each unit has one purpose, a clear interface, and
is testable in isolation.

- **`AudioEngine`** — `@Observable`; published state main-isolated, audio work off-main. Wraps
  `AVAudioEngine` + `AVAudioPlayerNode`. Owns `queue / index / isPlaying / progress / shuffle /
  repeat / nowPlayingContext`. **`progress` and the close-up's `centerTime` derive from the player
  node sample time** (`playerTime` / `lastRenderTime`), never a wall-clock timer. Drives
  `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`; configures `AVAudioSession(.playback)` and
  the Audio background mode. Installs the main-mixer tap feeding the live LUFS meter. Behaviors per
  handoff §03D: prev restarts if >5% in else previous; next at end-of-queue stops unless repeat.
- **`LibraryStore`** — SwiftData `ModelContainer` with `Track` and `Playlist` (per handoff §04).
  Playlist ordering uses an explicit `[UUID]` order array (SwiftData relationships aren't reliably
  ordered). v1 import is `UIDocumentPickerViewController(.audio)` + security-scoped bookmarks, plus
  optional **bundled demo tracks** for instant first-run content. The document picker stays in v1;
  the *Sources hub*, provider management, and "go to source folder" are the v2 cut.
- **`WaveformAnalyzer`** — an `actor`, off the main thread. On import / first play: `AVAssetReader`
  decodes PCM → `nano_dsp.analyze` → packed `[Bin]` → `WaveformCache` (on disk, keyed by content
  hash). The same pass yields `integratedLUFS` and the artwork tint. **One decode per file, ever.**
- **`WaveformCache`** — disk store keyed by content hash; holds compact packed bins. Survives even
  when a (future cloud) file isn't resident.
- **Renderers (SwiftUI `Canvas`), all consuming the same cached `[Bin]`:**
  - `OverviewWaveform` — ~150 bars; played full color, upcoming at 20% alpha; 2pt playhead with
    glow; whole strip scrubs → `engine.seek`; floating LUFS badge top-right; 62pt in Now Playing.
  - `CloseUpWaveform` — `TimelineView(.animation)` / `CADisplayLink`; windows the cached bins
    (~9s across, ~7 bars/sec) around `centerTime`; fixed center playhead with cap dots; played side
    42% alpha, upcoming full; edge fade ≈14% of width. No live audio path.
  - `MiniWave` — tiny static variant for rows / mini player.
  - `LufsBadge` — formats short-term `S` (`@Observable`, throttled ~10 Hz from the tap) and the
    static integrated value for rows.
- **Navigation / chrome** — `RootTabView` with the **custom glass tab bar** overlaid (system tab
  bar hidden), order fixed `[.library, .playlists, .search]`; `MiniPlayer` docked above it;
  `NowPlaying` presented full-screen with **`matchedGeometryEffect`** morphing the 44pt mini
  artwork to the hero. Tab bar hides while Now Playing is up.
- **`Theme`** — `Color`/font tokens straight from handoff §01 (`.continuous` radii, SF Pro + SF
  Mono with `.monospacedDigit()` for all numerics, system materials for glass). **`@AppStorage`**
  holds `zoomWave / showWave / spectrum` — the single source of truth Now Playing reads; toggled
  only in the Settings sheet.

### Why native rendering, not nano-render (for the ADR amendment)

The reusable IP for the waveforms lives in `nano-dsp` (band-split, color, the scroll control law),
not `nano-render` (wgpu draw calls + layout). For a *player*, the scroll control law isn't needed
(decision 2). What remains in `nano-render` is GPU plumbing for what amounts to a few hundred
rounded rects — cheap to express in `Canvas`, expensive to reach via a wgpu/Metal/Xcode
cross-build. Reusing `nano-render` would also still leave us writing `Canvas` for the overview
(handoff says build it natively) and the mini waveforms (can't host a Metal layer per row) — i.e.
*two* render paths on iOS instead of one. The handoff's own performance note keeps the escape hatch:
try `Canvas`/`TimelineView` first, move the close-up to Metal only if 120 Hz ProMotion shows jank —
which is the point at which linking `nano-render` would actually pay for itself.

## Scope

**In this plan (playable core + soul features, local files only):**

- Phase 0 — workspace relocation + `nano-dsp` carve + FFI `.xcframework` + ADR amendment.
- Phase 1 — shell: project, `Theme`, `RootTabView` + glass tab bar, SwiftData models,
  document-picker import + demo tracks, Library / Playlists / Detail / Search with `NMRow`.
- Phase 2 — local playback: `AudioEngine`, transport, queue/context, sample-time progress,
  `MPNowPlayingInfoCenter` / remote commands, `MiniPlayer`.
- Phase 3 — overview waveform + per-track LUFS: `WaveformAnalyzer` + `WaveformCache`,
  `OverviewWaveform` + scrub, `MiniWave`, integrated LUFS in rows.
- Phase 4 — Now Playing + transition: full screen, `matchedGeometryEffect`, artwork-tint gradient,
  transport / volume / bottom rail, Settings sheet (`@AppStorage`), all sheets *except* cloud ones.
- Phase 5 — close-up + live short-term LUFS: `CloseUpWaveform` from cached bins + sample-accurate
  `centerTime`; live BS.1770 meter via the main-mixer tap → `LufsBadge`.

**Deferred to v2 (separate plan):** full multi-source — the Sources hub, provider connect
(iCloud / Google Drive / OneDrive / Dropbox via File Providers), cross-provider security-scoped
bookmark management, "go to source folder" + its sheet, and cloud file materialization/availability.

**Out of scope:** iPad-specific layouts, anything not in the handoff. Target is iPhone, portrait,
iOS 17+ (SwiftData).

## Testing

- **`nano-dsp`:** the existing `WaveStore` / `loudness` / `color` unit tests move with the carve;
  add FFI tests (sine buffer → expected band; known-LUFS buffer → expected value within tolerance).
- **Plugin regression:** `./build.sh` + `auval -v aufx Nano Wlsp` green after the relocation/carve
  (the stated gate). Verify in a *new* Logic project (per CLAUDE.md cache traps).
- **Swift:** unit tests for `WaveformAnalyzer` (known WAV → bins), `AudioEngine` queue logic
  (next / prev / repeat, prev-restart-threshold), and `WaveformCache` round-trip. UI checked against
  the four reference screenshots and the prototype.

## Risks & mitigations

1. **Rust→iOS cross-build** — the one genuinely novel piece. *Retired first*: Phase 0 builds the
   `.xcframework` and proves it with a Swift smoke test before any UI depends on it.
2. **`Canvas` close-up at 120 Hz ProMotion** — simple rects should hold; the Metal escape hatch
   (per handoff) stays open if profiling shows jank.
3. **Color reconciliation** (handoff 4-discrete vs `nano-dsp` continuous) — resolved: use
   `nano-dsp`'s continuous color.
4. **Sample-time → `progress` accuracy across seeks** — derive from `playerTime`; well-trodden.
5. **Keeping the plugin green through the relocation+carve** — mechanical path edits; `./build.sh`
   + `auval` is the verifiable gate at the end of Phase 0.

## Open implementation-plan details (not blockers)

- Exact FFI byte layout / error handling; whether the streaming meter is one struct or per-channel.
- Xcode project vs SwiftPM-only; how the `.xcframework` build is wired into the Rust toolchain
  (cargo target + a build script vs a manual step).
- Bin density chosen for the cache (must satisfy the close-up's ~7 bars/sec while aggregating down
  to ~150 for the overview) and the on-disk packed format.
- Exact title/wording of the new `0009` ADR (decision is pinned; phrasing is open).
