# Spectrum Analyzer Module Implementation Plan

> **For agentic workers:** Executed INLINE this session. The DSP is TDD (exact, testable); the GPU render is verified live. Conventional Commits, monorepo scopes (`feat(dsp):`, `feat(plugin):`).

**Goal:** A high-quality, *exact* Spectrum Analyzer Module — a multi-resolution FFT (fine at every frequency, responsive), drawn as a smooth per-pixel log-frequency curve in dB with a peak-hold overlay. No coarse bands.

**Architecture:** A platform-free `MultiResSpectrum` in `nano-dsp` (shared → TUI/iOS, ADR 0009) runs three real FFTs — 32k (bass), 8k (mid), 2k (high) — each Blackman-Harris windowed, overlap-hopped, and normalized to dBFS so a full-scale sine reads 0 dB regardless of size. Each log-frequency display point reads the FFT assigned to its octave (crossovers from a bins/octave target), peak-preserving across the bins in its cell, so the stitched curve is fine AND continuous. Live ballistics (fast attack / eased release) + a slowly-falling peak-hold run on the display array. The plugin `SpectrumModule` uploads the magnitude + peak arrays and renders a filled curve + peak line + log/dB grid with `wgpu_text` axis labels.

**Tech Stack:** Rust, `realfft` (rustfft real-input wrapper — pure Rust, platform-free, fits nano-dsp), wgpu, wgpu_text. Tests: `cargo test -p nano-dsp` (DSP), `cargo test -p nanometers --lib` (registration).

**Design decisions (locked with the user, 2026-06-14):**
- **Multi-resolution FFT**, sizes 32768 / 8192 / 2048, stitched per-octave (the user's pick over single-FFT / constant-Q).
- **Live + peak-hold** ballistics, with **tunable** response.
- **Tunable params via on-screen KNOBS** (a new reusable UI primitive — the pattern for every module's
  settings): **Release**, **Attack/smoothing**, and **dB range/floor**. Persisted in the module config
  (ADR 0003 / F1). No Slope knob — exact dBFS is the default (a tilt can be added later).
- `realfft` library (not hand-rolled — the loudness biquad trade doesn't carry to FFTs).
- **Blackman-Harris** window (low leakage → exact peaks); coherent-gain normalization → 0 dBFS sine = 0 dB.
- Log frequency **20 Hz – min(20 kHz, Nyquist)**, **dB**, smooth **per-pixel filled curve** + peak-hold
  line, **labeled** Hz/dB grid.
- **Channel:** mono sum `(L+R)/2` for v1 (per-channel/mid-side a later option).
- `intrinsic_width` → `None` (flex; spectra want width).

---

## Slice 1 — `nano-dsp::spectrum` multi-resolution FFT core (TDD — the exactness lives here)

**Files:** add `realfft` to `[workspace.dependencies]` + `crates/nano-dsp/Cargo.toml`; create `crates/nano-dsp/src/spectrum.rs`; `pub mod spectrum;` in lib.rs.

Design:
- `struct ResBand { fft, window: Vec<f32>, win_sum: f32, ring: Vec<f32>, write, hop, since_hop, scratch, spectrum_db: Vec<f32> }` — one per size.
- `MultiResSpectrum::new(sample_rate, n_points)`:
  - three `ResBand`s for N ∈ {32768, 8192, 2048} (clamped ≤ a sane max; skip sizes > some cap for low SR).
  - Blackman-Harris window per band; `win_sum = Σw`.
  - **crossovers** from `BINS_PER_OCT_TARGET` (24): a band of size N is "usable" above `target·fs/N`; assign each display point to the SHORTEST usable band (best time response) → `band_of[point]`.
  - log-frequency grid: `f[p] = F_LO · (F_HI/F_LO)^(p/(n_points−1))`, `F_LO=20`, `F_HI=min(20000, fs/2)`.
- `push(mono: f32)` → into all three rings; tick each band's `since_hop`; when a band hits its hop, FFT it.
- per-band FFT: window the last N samples, real-FFT, magnitude, normalize: `db = 20·log10( |X[k]|·2 / win_sum + 1e-12 )` (single-sided; the `·2/win_sum` coherent-gain term makes a full-scale sine read 0 dB for ANY N).
- `magnitudes_db(&mut self) -> &[f32]`: for each display point, read its assigned band, take the **max dB** over the bins whose center falls in the point's frequency cell `[√(f[p-1]·f[p]), √(f[p]·f[p+1])]` (peak-preserving, no missed peaks), bilinear-ish when a cell is narrower than a bin.

- [ ] **Step 1 (RED):** `cargo test -p nano-dsp spectrum` tests:
  - `full_scale_sine_reads_0db_at_its_frequency`: 1 kHz, amplitude 1.0 → the max display point is within a few % of 1 kHz and its dB is within ±0.5 of 0.
  - `normalization_is_consistent_across_bands`: a sine in the 2k band's range (e.g. 5 kHz) and one in the 32k band's range (e.g. 50 Hz), both full-scale → both read 0 dB ±1 (proves cross-FFT normalization).
  - `low_frequency_is_resolved_finely`: a 40 Hz tone → the peak point's frequency is within ~1 Hz (the 32k band gives the resolution; a single small FFT would smear it).
  - `crossovers_are_continuous`: full-scale white noise → the stitched dB curve has no jump > ~3 dB across either crossover point (consistent normalization + sensible crossovers).
  - `silence_is_floor_not_nan`: zeros → all points at the dB floor, finite.
- [ ] **Step 2:** run → FAIL. **Step 3 (GREEN):** implement. **Step 4:** PASS. **Step 5:** commit `feat(dsp): multi-resolution FFT spectrum core`.

## Slice 2 — Display ballistics: live attack/release + peak-hold (TDD)

**Files:** `crates/nano-dsp/src/spectrum.rs` (extend).

- `SpectrumDisplay { live: Vec<f32>, peak: Vec<f32> }` updated from `magnitudes_db` each frame with `dt`:
  - live: instant rise (or fast attack), eased fall — `live = max(mag, live − FALL·dt)` with a small attack smٰooth.
  - peak: `peak = max(mag, peak)`, then decay `peak −= PEAK_FALL·dt` after a short hold.
- [ ] **Step 1 (RED):** tests:
  - `live_attacks_fast_releases_slow`: feed a high value then a low value across frames → live jumps up immediately, falls gradually.
  - `peak_holds_then_decays`: a transient peak is held above the (now-lower) live value, then decays toward it.
- [ ] **Step 2–4:** red → green. **Step 5:** commit `feat(dsp): spectrum live + peak-hold ballistics`.

## Slice 3 — Registration + module stub

**Files:** `layout.rs` (module_type `SPECTRUM`), `module/mod.rs` (`pub mod spectrum;`), `editor.rs` (`build_module` arm + import), `menu.rs` ("Add Spectrum" + update the menu count tests), new `module/spectrum.rs` (compiling stub Module).
- [ ] Wire all 5 sites; update the menu item-count tests; `cargo test -p nanometers --lib` green. Commit `feat(plugin): register the Spectrum module`.

## Slice 4 — GPU render: filled curve + peak line + labeled grid (live-verified)

**Files:** `apps/nano-plugin/src/module/spectrum.rs`.
- own a `MultiResSpectrum` + `SpectrumDisplay` (created/reset on sample-rate change, like Loudness).
- `update`: push `ctx.new` mono; advance ballistics by `frame_dt`; build the GPU buffers — a filled triangle-strip from the curve to the floor (`n_points·2` verts), and a LineStrip for the peak overlay; map dB→y (`db_to_y` over the range) and log-freq→x (the point index → x).
- a quad/line pipeline (reuse the Stereometer/Loudness vertex pattern: `pos + color`); the fill softly translucent, the line crisp.
- `prepare`: a log-frequency grid (decade lines at 100/1k/10k + the 2·5 ticks) and dB grid (e.g. every 12 dB), with `wgpu_text` labels (shared `FONT`) — *labeled axes are part of "high quality."*
- `render`: grid, fill, live line, peak line, labels.
- [ ] **Verify:** dev-player — a tone shows a sharp peak at the right place reading ~0 dB; sweep it and the peak tracks finely down to the low bass (no stair-stepping); music shows a smooth detailed curve; peak-hold catches transients. Commit `feat(plugin): render the Spectrum analyzer`.

## Slice 5 — On-screen knob primitive + tunable, persisted params

**Files:** new `apps/nano-plugin/src/module/knob.rs` (reusable); `module/spectrum.rs` (own + place 3 knobs); a `SpectrumConfig` (serde) in `module/spectrum.rs`.

- **`Knob`** (pure where possible, GPU/event where not): `{ center, radius, value01: f32, label }`.
  - `value01` ↔ a real param via a (possibly log) range mapped by the owner.
  - hit-test: `contains(local_xy)`; **drag**: a press inside captures (`EventStatus::Captured` → the
    Module grab forwards the drag), vertical drag changes `value01` (up = increase, scaled), release ends.
  - render: an arc track + a filled value arc + the indicator, the label, and the value readout
    (`wgpu_text`). Reuse the line/quad pipeline + shared `FONT`.
  - pure-testable bits: `value_from_drag(start_value, dy, sensitivity)` (clamped 0..1), the
    param↔value01 range map (e.g. release 20 ms…2 s log) — unit-test these.
- **`SpectrumConfig { release_ms, attack_ms, db_floor }`** (serde, like `WaveformConfig`): `to_bytes`/
  `from_bytes`; `save_config`/`load_config` route through it. The DSP ballistics + the dB→y mapping read
  these each frame.
- Spectrum `on_event`: track last local cursor; a press hit-tests the 3 knobs → Module grab → drag
  updates the knob's `value01` → writes the mapped param into `SpectrumConfig`. Returning `Captured`
  routes the drag here; the host flushes config after the discrete batch (F1) so it persists.
- [ ] Unit-test the pure knob math + the SpectrumConfig round-trip; live-verify dragging a knob changes
  the response (and survives save/reopen). Commit `feat(plugin): on-screen knobs + tunable spectrum params`.

## Slice 6 — docs + verify + merge
- [ ] Spec `docs/specs/spectrum-module.md` (the multi-res scheme, normalization, crossovers, ballistics, deferred: per-channel, tilt). README already lists Spectrum Analyzer.
- [ ] `cargo test -p nano-dsp` + `-p nanometers` green; clippy clean on the new files; live look; user confirms; `code-review` over the diff; merge `feat(plugin): add the Spectrum Analyzer module` → main + push.

---

## Self-review notes
- **Exactness is testable:** the Slice-1 tests pin 0 dBFS calibration, cross-band normalization, fine low-freq resolution, and crossover continuity — the four ways "coarse/inexact" would show.
- **Shared-core safety:** `spectrum` is a NEW nano-dsp module; it doesn't touch loudness numerics (no iOS-FFI drift). `realfft` is a new platform-free runtime dep — the first since `atomic_float`; justified by the user's exactness bar (an FFT is not worth hand-rolling).
- **Peak-preserving display mapping** (max-bin-per-cell) is what keeps a swept tone from stair-stepping or vanishing between display points — the difference between "fine" and "looks fine until you sweep it."
