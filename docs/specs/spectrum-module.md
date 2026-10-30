# Spectrum Analyzer Module

A log-frequency, dBFS spectrum of the mono sum `(L+R)/2`: a smooth filled live curve plus a
peak-hold line over a labeled Hz/dB grid. Flex width (`intrinsic_width` → `None`). Plan:
[`2026-06-14-spectrum-analyzer.md`](../superpowers/plans/2026-06-14-spectrum-analyzer.md).

## DSP — `nano-dsp::spectrum` (platform-free, ADR 0009)

- **Multi-resolution FFT.** Three real FFTs (`realfft`) — 16384 (bass) / 8192 (mid) / 2048
  (treble) — each Blackman-Harris windowed and hop-updated (hop capped at 1024). The long FFT was
  32k originally; dropped to 16k because its ~683 ms window made the bass lag the rest.
- **Normalization.** `|X[k]|·2 / Σw` (coherent gain, single-sided) so a full-scale sine reads
  0 dBFS at any FFT size. Floor −140 dB, never NaN.
- **Display points.** ~24/octave on a log grid, 20 Hz – min(20 kHz, Nyquist). Each point takes the
  **max** over the bins in its frequency cell (peak-preserving — a swept tone never vanishes
  between points).
- **Crossovers.** A band is usable above `24 bins/oct · fs/N`; adjacent bands are blended with a
  partition-of-unity crossfade, so tones stay 0 dB through the seam and the bandwidth-dependent
  noise floor ramps instead of stepping.
- **Ballistics (`SpectrumDisplay`).** Asymmetric one-pole live trace (attack / release in ms) and
  a peak-hold that latches, holds 1.2 s, then falls at 24 dB/s.

## Render — `module/spectrum.rs`

Catmull-Rom-interpolated curve drawn into the Module's own 4× MSAA offscreen (ADR 0007, like the
Waveform), resolved and composited 1:1. Gradient fill (bright at the curve → transparent at the
floor) so the AA'd fill edge *is* the curve; subtle peak line; grid AA'd with the rest;
`wgpu_text` labels on top. Range: `db_floor` … +6 dB.

## Config (ADR 0003, persisted)

`SpectrumConfig { release_ms: 250, attack_ms: 12, db_floor: -100 }`, round-tripped through
`save_config`/`load_config`.

## Deferred

- **On-screen knobs** (plan Slice 5) to tune release / attack / floor — the config is persisted
  but nothing edits it yet; it boots at defaults. Meant to be a reusable knob primitive for every
  Module's settings.
- Per-channel / mid-side view; a slope (tilt) option.
