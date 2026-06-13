# Now Playing redesign — cover-flip hero + analysis rack (iOS)

Status: **approved** (2026-06-13). Implements the design handoff
`design_handoff_nanometers-player_redesign` (docs 01/05/06 + `design_reference/*.jsx`,
which are the source of truth for exact values). Worktree: `player-redesign`.

The handoff's `.jsx` files are the authority for pixel values; this spec records the
*decisions* (including where the user overrode the handoff) and the native mapping.

---

## 1. Goal

Rework the iOS `NowPlayingScreen` into the producer-first player: the album cover is the
hero and **flips** to an analysis "B-side" — a close-up stereo scope, a goniometer, and a
smooth spectrum — with a tiny icon switcher and a loudness badge. The existing mini ⇄ Now
Playing **zoom transition stays** (it is orthogonal; the flip lives inside the cover).

Personality: Pro, dark warm-charcoal, accent amber `#EFA869`, mono numerics.

## 2. Decisions (incl. user overrides of the handoff)

| # | Topic | Decision |
|---|---|---|
| D1 | Close-up model | **Handoff scrubber interaction** (center playhead, shows upcoming audio, scrub-to-seek) rendered in the **nano-plugin's filled min/max stereo contour** look (L top half, R bottom half, spectral color). Fed from a pre-analyzed **stereo cache** (not the live tap). |
| D2 | Close-up density | Cache gains a **separate, denser stereo array (~50 bins/s)** for the close-up; the existing **mono overview bins (10/s) stay byte-identical** (no overview regression). |
| D3 | LUFS badge | **Keep momentary M (400 ms)** as currently shipped; relocate it to the card top-right. Label stays **"M"**. (Handoff said "S"; user kept M.) |
| D4 | Bottom rail | **Keep AirPlay.** Rail = folder · gear (Settings) · AirPlay · queue (4 icons). (Handoff dropped AirPlay; user kept it.) |
| D5 | Title format line | **Add bit-depth extraction** on import → render literal "FLAC · 24/96"; fall back to "format · rate kHz" when no bit depth (lossy files). |
| D6 | Idle meters | Goniometer + spectrum **fade to idle** when no live audio (gonio → center dot, spectrum → floor). |
| D7 | Background | **Neutral warm gradient + accent aura** (handoff §06F); drop the per-track album-art tint. `ArtworkTintStore` becomes unused by NP (left in place). |
| D8 | Coloring default | Frequency-coloring `@AppStorage("spectrum")` default flips **off → on** (handoff default). |
| D9 | `zoomWave` | Retired — the close-up is now always reachable via the flip. |

## 3. Architecture overview

```
AudioEngine (existing tap on mainMixerNode)
├── LiveLUFSMeter (existing)         → momentary M LUFS  (unchanged)
└── LiveScopeTap (NEW)              → lock-guarded ring of recent L/R frames
                                       → Goniometer (M/S scatter)
                                       → Spectrum (vDSP FFT → 72 log bins)

WaveformAnalyzer (one decode/file)
├── nano_dsp_analyze (mono)         → overview bins (10/s, peak+rgb)   UNCHANGED
└── nano_dsp_analyze_stereo (NEW)   → close-up bins (~50/s, lMin/lMax/rMin/rMax+rgb)
        → WaveformCache v2 (mono array + stereo array)

NowPlayingScreen
└── FlipHero (front: NMArtwork · back: AnalysisArea)
        AnalysisArea = ModSwitch + CloseUpWaveform + Goniometer + Spectrum + LUFSBadge
```

## 4. DSP / data contracts

### 4.1 New FFI — stereo close-up analysis
Add to `crates/nano-dsp/src/ffi.rs` + `include/nano_dsp.h`:

```c
typedef struct NanoStereoBin {
    float l_min, l_max;   // left  channel min/max envelope for the column
    float r_min, r_max;   // right channel min/max envelope
    float r, g, b;        // sRGB band color for the column (band_color of band_ms)
} NanoStereoBin;

// Build a WaveStore from de-interleaved L/R, merge to n_bins columns, fill out[].
// Envelopes normalized so the largest |min|/|max| across both channels maps to 1.0
// (soft-knee like nano_dsp_analyze). Returns 0 ok, -1 on bad args.
int32_t nano_dsp_analyze_stereo(const float *l, const float *r, size_t len,
                                float sample_rate, size_t n_bins, NanoStereoBin *out);
```
Pure reuse of `WaveStore` (per-channel `ChannelEnvelope{min,max}`, `band_ms[3]`) +
`band_color`. Rust unit test mirrors the existing analyze test (tone → finite, colored).

> Note: the existing **`nano_meter_short_term`** already exists in `ffi.rs` but is missing
> from `nano_dsp.h`; add the declaration while here (harmless, used by no one yet).

### 4.2 Swift bridge
`NanoDSPBridge.analyzeStereo(l:[Float], r:[Float], sampleRate:Double, binCount:Int) -> [StereoWaveBin]?`
mirrors `analyze`. New value type:

```swift
struct StereoWaveBin: Equatable { var lMin, lMax, rMin, rMax, r, g, b: Float }
```

### 4.3 Cache v2 (`WaveformCache`)
- Bump `version` **1 → 2**. v1 files fail the version check → cache miss → re-analyze
  (transparent; no data loss). Bump informs all `.nmwave` readers.
- Layout: existing header (magic, version, sampleRate, duration, integratedLUFS) +
  `monoBinCount` + mono `WaveBin[]` (unchanged 16-byte records) + `stereoBinCount` +
  `StereoWaveBin[]` (28-byte records, Float32 LE).
- `WaveBin` stays exactly as today (overview unchanged). `StereoWaveBin` is the new record.
- `WaveformStore`: `bins(for:)` → mono (overview/mini). New `closeUpBins(for:)` → stereo.
- Density constants in `WaveformAnalyzer`: `binsPerSecond = 10` (mono, unchanged),
  `closeUpBinsPerSecond = 50` (stereo, tunable — documents the cache-size/fidelity trade).
  Stereo count = `max(450, Int(durationSec * 50))`.

### 4.4 Live scope tap (goniometer + spectrum)
- New `LiveScopeTap` (Sendable, lock-guarded), fed from the **existing** mixer tap callback
  alongside `LiveLUFSMeter`: copies interleaved L/R into a ring (≥ 4096 frames). No
  allocation on the audio thread.
- `snapshot(count:) -> (l:[Float], r:[Float])` returns the most recent `count` frames on the
  main actor for the UI.
- Goniometer reads ~1024 recent frames; spectrum runs a Hann-windowed `vDSP` real FFT over
  ~2048 frames → magnitudes → 72 log-spaced bins.
- AudioEngine clears/decays the tap on pause/stop/track-change (mirrors `liveMeter`).

## 5. Theme additions (`Theme.swift`)
Add tokens used by the redesign (values from `01-design-tokens.md` / jsx):
- NP background stops: `npBgTop #232029`, `npBgMid #1A1820`, `npBgBottom #131218` (168°).
- Card-back gradient: `cardBackTop #221F2A`, `cardBackMid #18171F`, `cardBackBottom #131218` (158°).
- Accent aura uses `Theme.accent` @0.16.
- Radii: `flipCard = 22`.
- Keep existing band colors; close-up applies an 18% white-mix (`COLOR_WHITE_MIX`) like the plugin.

## 6. NowPlayingScreen layout (top → bottom)

Spacing/sizes from `screens-now.jsx`:

1. **Top bar** — chevron-down (`npDismiss`, 26) · centered context (kind mono 10 / tracking 1.6 / white@42% over name 13 semibold) · ellipsis (`npEllipsis`, 24).
2. **FlipHero** — square, `maxWidth 350`, `aspectRatio 1`, centered, radius **22**, shadow `0 28 56 black@0.42`. Takes the leftover vertical space (caps at 350).
3. **Title row** — title (`npTitle`, 21/700, tracking −0.3, lineLimit 1) over [artist 15 white@58% · **format line** mono 10.5 tracking 0.4 text3]; trailing heart (`npHeart`, 24, accent when loved). **No artwork thumbnail.**
4. **Overview scrubber** — `OverviewWaveform` at **height 30** (was 46), `coloringOn = spectrum`, `onScrub = seek`. Below it: mono 11.5 white@46%, **elapsed left / -remaining right only** (no LUFS). `showWave == false` → plain capsule bar with a 13pt white knob.
5. **Transport** — shuffle (22, accent when on) · prev (34) · **play 70pt** amber circle, glyph `#15171E`, shadow `0 10 26 accent@0.4` (`npPlayPause`) · next (34) · repeat (22, accent when on).
6. **Volume** — wave glyph 16 · slider (white@85% fill, white knob) (`npVolume`) · wave glyph 22.
7. **Bottom rail** — folder (22, disabled v2 placeholder as today) · **gear** → Settings (`settingsButton`/`npSettings`) · **AirPlay** (`AirPlayButton`) · queue (24, `npQueue`). 4 icons, evenly spaced, white@78%.

Background: `LinearGradient(168°, npBgTop→npBgMid@0.44→npBgBottom)` full-bleed
(`.ignoresSafeArea`) + a top accent aura (`RadialGradient` accent@0.16, ~300pt). Chrome
padded by the threaded `safeArea` (unchanged mechanism from `RootView`).

## 7. FlipHero
- `ZStack { front; back }` with `.rotation3DEffect(.degrees(flipped ? 180 : 0), axis:(0,1,0), perspective ~0.5)`.
- Backface hiding: each face gated on the half-angle via `.opacity` (front visible when angle < 90°, back when > 90°); back content pre-counter-rotated 180° so it reads correctly.
- Flip animation: spring (`.spring(response:0.5, dampingFraction:0.82)`), mapping the jsx `0.62s cubic-bezier`.
- **Front** = `NMArtwork` filling the square; the whole face is the flip target (tap → flip to back). No corner button.
- **Back** = card-back gradient (158°) + inset hairline; holds `AnalysisArea`, a flip-back button top-left (`npFlipBack`, flip glyph, 32pt glass circle), and the LUFS badge top-right.
- `flipped` is local state, **resets to front on track change** (`.onChange(of: current.id)`).
- Analysis meters animate only while `flipped && npOpen`.
- Accessibility: front exposes `npArtwork`/flip action; back container `analysisArea`.

## 8. AnalysisArea (`analysis.jsx` mapping)
A vertical stack (padding `12,12,40`) gated by the selected `modules` set:

| Selected | Arrangement |
|---|---|
| scope only | scope fills |
| scope + one | scope (flex 1.3) on top; the other full-width below (flex 1.3) |
| scope + gonio + spectrum | scope on top; below: gonio (40%) + spectrum (60%) side by side |
| gonio + spectrum (no scope) | stacked vertically |
| gonio only / spectrum only | fills |

- **ModSwitch** — bottom-center glass pill (`rgba(20,20,26,0.4)` material + inset hairline white@0.12, radius 16, padding 4). Three 34×28 buttons (radius 12): scope (bars glyph), gonio (diamond), spectrum (curve). Active = accent@0.18 fill + accent glyph; inactive = white@40% glyph. Multi-select; **at least one always on** (tapping the last-on is a no-op). IDs `modScope`/`modGonio`/`modSpectrum`.
- **LUFS badge** — top-right (top 9, right 11): `LUFSBadge(lufs: engine.momentaryLUFS)` (label "M"), small pill `black@0.26` + inset hairline. Removed from the scrubber row.

## 9. The three meters

### 9.1 CloseUpWaveform (rewrite of the renderer; keep `ScrollClock`)
- Input: **dense stereo bins** (`[StereoWaveBin]`) + `currentTime` (sample clock) + `duration` + `coloringOn` + `isPlaying` + `redrawTrigger` + `windowSec`.
- Keep the `ScrollClock` subway-sign smoothing and `TimelineView(.animation(paused:!isPlaying))` (port already in tree); window = `windowSec` (3/4/5, default 4) instead of the hardcoded 9.
- **Draw = filled min/max stereo contour**, plugin-style:
  - Two half-panels: **L in top half** (zero-line `H*0.25`), **R in bottom half** (zero-line `H*0.75`); excursion `±0.45 * (H/2)`.
  - Pixel-per-column: for each device column x, map to fractional bin index (window around the smoothed center), sample (nearest/linear) the stereo bin, and **fill the vertical segment between min and max** for each channel (filled envelope, not a single bar).
  - Color per column = band color (stored rgb) + 18% white-mix when `coloringOn`, else `accent`.
  - **Uniform brightness** (remove the 0.42 played-side dimming). Soft **edge fade** `clamp(min(x, W-x)/(W*0.10),0,1)`.
  - **Center playhead**: 2pt white vertical line + 2.6pt cap dots; whisper-faint center axis `white@0.05` at `H/2`.
  - **Scrub**: `DragGesture` over the scope maps x → `center + (x - W/2)/W * windowSec` → `seek(toFraction:)` (new — handoff §06D.1).
- Keep `accessibilityIdentifier("closeUpWaveform")`. Strip chrome optional (`CLOSE-UP` label per §05; analysis rack is label-free per §06 — **omit the label** to match §06's no-chrome direction).

### 9.2 Goniometer (new `Goniometer.swift`)
- `TimelineView(.animation)` gated on `active` (flipped && npOpen && gonio selected).
- Read `LiveScopeTap.snapshot(count: ~1024)`; for each pair: `M=(L+R)*0.7071`, `S=(L-R)*0.7071`; `x = cx + S*R`, `y = cy - M*R`, `R = min(W,H)/2 - 8`.
- Accent phosphor, **`ctx.blendMode = .plusLighter`**; per-point alpha `0.16 + 0.45*(|M|+|S|)`, ~1.6pt dots. Faint diamond + cross guide (white@0.06). No labels.
- **Idle**: when not playing / silent, lerp the displayed spread + alpha toward 0 (collapses to a center dot). ID `goniometer`.

### 9.3 Spectrum (new `Spectrum.swift`)
- `TimelineView(.animation)` gated on `active`. Read `snapshot(count: ~2048)`, Hann window, `vDSP` real FFT → magnitudes → **72 log-spaced bins**.
- Temporal smoothing `V += (target − V) * 0.22`. Build a **quadratic-smoothed filled path**; fill = vertical accent gradient (`@0.55 → @0.04`); bright accent top line (1.5pt, `@0.95`). No grid/axis/labels.
- **Idle**: target → floor when no live audio (decays to the baseline). ID `spectrum`.

## 10. Settings sheet (`SettingsSheet` rewrite)
Native `.sheet` (`.presentationBackground(.regularMaterial)`, detents medium/large), title
"Settings" (24/700), one **Analysis** group (footer: "Tap the meter icons in the player to
switch between close-up, goniometer and spectrum — show one or several at once."):
- **Frequency coloring** — `Toggle`, accent tint, sub "Close-up: red bass · green mids · blue treble" → `@AppStorage("spectrum")`.
- **Close-up window** — segmented 3s/4s/5s, mono labels → `@AppStorage("scopeWindow")` (Int, default 4).
- **Track overview scrubber** — `Toggle`, sub "Whole-song waveform seek bar" → `@AppStorage("showWave")`.

Opened from the gear in the NP bottom rail.

## 11. Persisted state (`@AppStorage`)
| Key | Type | Default | Meaning |
|---|---|---|---|
| `modules` | String (CSV) | `"scope"` | selected meters; parsed to an ordered set, min 1 |
| `scopeWindow` | Int | `4` | close-up window seconds (3/4/5) |
| `spectrum` | Bool | **`true`** | frequency coloring (close-up only) |
| `showWave` | Bool | `true` | overview scrubber vs plain bar |
| ~~`zoomWave`~~ | — | — | **removed** |

`modules` helper: a small wrapper around the CSV string exposing `Set<Module>` with a
toggle that refuses to remove the last element.

## 12. Bit-depth extraction (D5)
`TrackImporter` (and `DemoSeed`) read `AVAudioFile(forReading:).fileFormat` →
`streamDescription.pointee.mBitsPerChannel`; store `Track.bitDepth: Int?` (0 → nil; lossy).
Additive SwiftData field (lightweight migration, default nil). Format line:
`bitDepth != nil ? "\(format) · \(bitDepth)/\(sampleRate)" : "\(format) · \(sampleRate) kHz"`.

## 13. Known changes (transparency — all design intent, no silent regressions)
Cache v2 one-time re-analysis · neutral gradient replaces album-art tint · `spectrum`
default off→on · scrubber 46→30 · play 64→70 · LUFS leaves scrubber row · `zoomWave`
removed · new `Track.bitDepth`.

## 14. Testing

### Unit (`Tests/`)
- `NanoDSPLinkTests`: stereo analyze on a tone → finite envelopes, sensible color; short-term FFI smoke.
- `WaveformCacheTests`: v2 roundtrip (mono + stereo arrays), v1 file rejected (→ re-analyze), version constant == 2.
- `WaveformAnalyzerTests`: mono still 10/s (unchanged); stereo ~50/s; stereo bins normalized 0…1.
- New `SpectrumMathTests` (log-bin mapping monotonic, bins == 72) and `GoniometerMathTests` (M/S transform: mono → vertical line, hard-left → off-axis).
- `ModuleSelectionTests`: CSV parse/serialize; min-1 invariant.

### UI (`UITests/`) — preserve all 16 existing IDs; add:
- Flip to analysis (`npArtwork` tap → `analysisArea` visible) and back (`npFlipBack` → artwork).
- Module toggles: enabling each shows `closeUpWaveform`/`goniometer`/`spectrum`; min-1 (turning all off leaves one on).
- M-LUFS badge present on the card.
- Settings: gear → sheet → toggle coloring / pick window / toggle scrubber persists.
- Existing flows (`overviewWaveform` scrub, mini ⇄ NP, transport) still pass.

### Manual verification
Boot the simulator with `-autoplay -expand`, screenshot: front cover, flipped analysis
(each module combo), settings sheet. Confirm against the handoff `.heic` references.

## 15. Implementation phases
- **A — Tokens + DSP core.** Theme tokens; `nano_dsp_analyze_stereo` + header + Rust test; Swift bridge + `StereoWaveBin`; cache v2 (mono+stereo) + `closeUpBins`; `LiveScopeTap` fed from the tap; bit-depth on import. Unit tests green; app still builds/runs unchanged UI.
- **B — Flip hero + new NP shell.** Neutral gradient + aura; flip card (front artwork, empty back); title format line; 30pt scrubber; 70pt play; 4-icon rail; LUFS off scrubber row. Screenshot front + empty back.
- **C — Close-up scope.** Filled stereo contour renderer (D1/D2) + scrub; wire into the back face. Screenshot.
- **D — Goniometer + spectrum.** Live Swift Canvas views + idle decay; `ModSwitch` + layout rules + persisted `modules`. Screenshot each combo.
- **E — Settings.** New Analysis sheet + `scopeWindow`/`spectrum`/`showWave`; wire window into the scope. Screenshot.
- **F — Tests + polish.** All UI tests; adversarial review; final screenshots vs `.heic`.

Adversarial code review after C, D, and F (and any phase that touched DSP).
