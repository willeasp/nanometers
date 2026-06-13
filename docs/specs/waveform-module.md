# Spec — Waveform Module

The buildable spec for the **Waveform** Module. It *compiles* the decisions in the glossary and the
ADRs into one place; where a decision and its rationale live in an ADR, this spec states the *what*
and links the *why*. It is not the place to relitigate decisions — open those ADRs.

**Sources:** `CONTEXT.md` (vocabulary) · ADR 0001 (coloring) · 0002 (data flow) · 0003 (layout /
config) · 0004 (input) · 0005 (text) · 0007 (rendering).

## 1. What it is

A Module showing the amplitude **envelope** over a broad, scrolling time window (seconds) — the
DJ/editor "waveform" view — **spectrally colored** by frequency content. Distinct from the
Oscilloscope (the zoomed real-time trace nanometers renders today). It supersedes the current
on-screen waveform; the fake 9-layer glow is removed (0007).

## 2. Data & threading (0002)

- Audio thread is untouched: it only pushes raw `[L, R]` into the ring. **All Waveform work is
  GUI-side**, folded online from `FrameContext { new: &[StereoFrame], meas, sample_rate, mono }`
  once per frame.
- **Per-instance store:** a ring of **base bins at 0.5 ms resolution** (samples-per-bin derived from
  the host `sample_rate`, read off the `FrameContext` — 0002). Each base bin holds:
  `{ env: [ChannelEnvelope; 2], band_low_ms, band_mid_ms, band_high_ms }`, where
  `ChannelEnvelope = { min, max, mean_square }` is kept **per channel** (L, R — the envelope is drawn
  per channel, §4) and the three per-band mean-squares are a **single shared set** (the filterbank
  analyzes the mono sum, so one set, not per channel — §3.2, 0001). All fields **merge associatively**
  (min/max trivially; mean-squares by sample-weighted average), so columns and zoom are cheap
  re-merges, never a raw re-scan.
- **History length** ≈ the max supported window + headroom (e.g. ~10 s of base bins); the *viewable*
  window is a config subset (§6).
- **Draw:** merge the visible base bins down to **pixel columns** for the current `viewport` width;
  scroll so the newest bin sits at the right edge.

## 3. DSP

### 3.1 Envelope
Per incoming sample, for each channel `ch`: update that channel's `env[ch].min`/`max`, accumulate
`sample²` into `env[ch].mean_square`. On a 0.5 ms boundary, finalize the bin and advance. (Store
mean-square, never RMS — `sqrt` only at draw, per 0002.)

### 3.2 Spectral color — 3-band filterbank (0001)
- Analyze the **mono sum `(L+R)/2`** through a **3-band filterbank**: low (≲ 250 Hz), mid, high
  (≳ 4 kHz) — biquad crossovers. Per sample, `band_power = filtered²`; accumulate each band's power
  into the bin's `band_*_ms`. Filterbank state is Module-internal and persists across frames; ring
  drop-on-starve is visually harmless.
- **Color per column** from the merged band mean-squares: normalize to the band *balance*; a dominant
  band drives the hue (low → red, mid → green, high → blue), spectral *imbalance* drives saturation,
  and balanced/broadband content desaturates toward **white** (0001 — *not* naïve additive RGB, which
  would make bass+air magenta). Exact mapping (balance/chroma-vector vs naïve additive) and white
  strength are **dev-player tuning** (§10), defaulting to the balance→white form.

## 4. Rendering (0007)

- **Per channel**, a triangle-strip **fill** between the column max-curve (top) and min-curve
  (bottom). **L fills the top half of the viewport, R the bottom** (within-Module layout only — no
  cross-Module spatial reference, per 0003).
- **One color per column**, carried on the strip vertices, interpolated along time.
- **Outline:** optional brighter line-strip over the silhouette; config toggle, default on (0007).
- **Anti-aliasing:** per-Module, not host-wide (0007). The Waveform renders its contour to its
  **own offscreen multisampled target** (= the future bloom target), resolved and composited into
  the viewport. The host shared pass stays single-sample; text self-AAs via its atlas (0005).
- The Module owns its wgpu pipeline(s) (0002) and draws into its `viewport: Rect`, clipped with
  `set_scissor_rect` (0003/0005).

## 5. Interaction (0004)

- **Hover → dB readout:** on pointer-move within the viewport, map cursor x → time → column and
  cursor y → channel (top half = L, bottom half = R) → that channel's `max` for the column in dBFS,
  drawn as text near the cursor (own `wgpu_text` brush, 0005), clipped to the viewport. This is the
  MiniMeters "click shows dB" affordance, on hover.
- **Return `Ignored` for all pointer events** so the host keeps ownership of press-drag **reorder**
  and boundary **resize** (0004). v1 captures nothing. (A future captured interaction — freeze /
  measure — would return `Captured`.)

## 6. Config — Module-owned opaque blob (0003)

Persisted per instance via the host's opaque-config path (host never reads the fields). The blob is
JSON-encoded (`serde_json`, the encoding the whole `EditorState` uses).

| field | default | notes |
|---|---|---|
| `window_seconds` | 5.0 | viewable window; **built (F1/F2)** — scroll the Waveform to zoom [1–8 s], persisted |
| `outline_enabled` | `true` | 0007 — future |
| `band_low_hz` | ~250 | low/mid crossover — future |
| `band_high_hz` | ~4000 | mid/high crossover — future |
| `color_white_strength` | tbd | how hard broadband desaturates to white — future |
| `palette` | tbd | optional later |

**Built so far (Phase F1):** the config persistence path is live (`save_config`/`load_config` route
through `WaveformConfig`, which today carries only `window_seconds`). The remaining fields and the UI
to edit them land later (F2+). Forward-compatible: a blob from a future build that carries extra
fields still restores `window_seconds` here (serde ignores unknown fields); only structurally-invalid
or empty bytes fall back to defaults (`from_bytes` never panics — the trait contract).

**Multi-instance (0003):** two Waveforms at different zooms is first-class. Each instance owns its
own store, filterbank state, and config — no shared global state.

## 7. Removed

The fake 9-layer additive-glow stacking (`GLOW_LAYERS`) and the full-buffer line draw. (Note: the
code's current "waveform" is conceptually the *Oscilloscope* — `CONTEXT.md`; this Module is the
broad scrolling Waveform and replaces what's on screen.)

## 8. Host coordination (with the Module-host / parallel agent)

- **`Module` trait** (compiled from 0002 + 0004 + 0003): `update(&ctx, &queue)`, the optional
  `prepare(&device, &queue, &mut encoder, viewport)` for the Module's **own offscreen passes**
  (§4 — the MSAA contour target the Waveform needs; default no-op), `render(&mut rpass, viewport)`,
  `on_event(&event, viewport) -> EventStatus`, and the opaque-config pair
  `save_config(&self) -> Vec<u8>` / `load_config(&mut self, &[u8])` ([0003]). The host's
  `set_scissor_rect(viewport)` only **clips** — the Waveform maps its own geometry into `viewport`
  ([0002]). Build the Waveform against exactly this (mirrors `apps/nano-plugin/src/module/mod.rs`).
- **No host AA dependency.** AA is per-Module (§4): the Waveform self-AAs via its own offscreen
  target, so the host's shared pass can stay single-sample. No sample-count coordination needed.
- **No shared spectrum** in `FrameContext` — the Waveform computes its own bands (0001); the host
  must not add a published FFT expecting us to consume it.

## 9. Build milestones (sequencing)

The trait is now fully specified, so the Waveform is built **as a real Module** against it; iterate
on the dev-player (which feeds the same ring → `FrameContext`).

1. **M1** — per-column min/max contour fill, mono, monochrome, scrolling, fixed window, on the
   dev-player (against a stub host or the real one).
2. **M2** — stereo L/R halves; outline toggle; AA via the Module's own offscreen multisampled
   target (the eventual bloom target).
3. **M3** — 3-band filterbank + balance→white color; tune live.
4. **M4** — hover dB readout (`wgpu_text`).
5. **M5** — opaque config blob + persistence; multi-instance.

Depends on the host providing `FrameContext`, the `Module` trait, and the `viewport`; can be
developed against the dev-player with a stub host until the real host lands.

## 10. Visual-tuning knobs (dial on the dev-player, not in ADRs)

Window length · band crossover Hz · color mapping form + white strength · outline on/off + brightness
· fill brightness/gamma. These are the parameters to play with on a real track once M3 is up.
