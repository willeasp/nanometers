# nanometers — glossary

The shared language of this codebase. Definitions only — no implementation details, no
decisions (those live in `docs/adr/`). When code and this file disagree, one of them is wrong;
fix it.

## Modules

- **Module** — one self-contained visualization or readout occupying its own rectangle in the
  window (the Waveform, the Oscilloscope, the Loudness Module, …). Each owns its own GPU
  pipeline(s) and draws into its own sub-rectangle of the surface; Modules are independently
  placed, resized, and configured. _Avoid_: View, sub-meter, panel, widget. "Meter" names only
  a level-readout Module, not the general class.
- **Oscilloscope** — a Module showing the instantaneous wave *shape* over a very short,
  real-time window (tens of ms). This is what nanometers renders today — the code still calls it
  "waveform". Free-running; pitch-following is optional and not yet present. _Avoid_: scope.
- **Waveform** — a Module showing the amplitude *envelope* over a broad time window (seconds),
  scrolling or static, like a DJ/editor track view. Each horizontal position summarizes a block
  of audio and can be colored by that block's content. Distinct from the Oscilloscope, which is
  a zoomed-in real-time trace. _Avoid_: oscilloscope, scope.
- **Spectrogram** — a Module showing frequency content over time as a scrolling heatmap:
  frequency on one axis, time on the other, magnitude as color/brightness. _Avoid_: waterfall,
  sonogram.
- **Spectrum Analyzer** — a Module showing the *current* frequency content as magnitude across
  the frequency axis (instantaneous, not historical). _Avoid_: spectrum (ambiguous with
  Spectrogram), FFT.
- **Stereometer** — a Module visualizing the stereo field: phase/correlation and L/R balance
  (Lissajous / goniometer / vectorscope styles). _Avoid_: goniometer (only one of its styles),
  vectorscope.
- **VU** — a Module emulating a classic VU meter: slow, averaged, needle-style level.

## Loudness

All loudness is measured per ITU-R BS.1770 / EBU R128. Units:

- **LUFS** — Loudness Units relative to Full Scale. An absolute loudness reading. "−14 LUFS".
- **LU** — Loudness Units. A *relative* difference between two loudnesses (the scale on the
  meter is in LU around a target; "+9 LU" is a range, not a level).
- **Loudness Module** — the Module showing the three loudness time scales.

The three **time scales** (a "time scale" is one integration window over which loudness is
measured):

- **Momentary (M)** — loudness over a sliding 400 ms window. Fast, twitchy.
- **Short-term (S)** — loudness over a sliding 3 s window. The most useful "how loud is this
  section" reading.
- **Integrated (I)** — gated loudness accumulated over the whole measurement since the last
  **reset**. The single "how loud is the whole track" number.

Supporting terms:

- **K-weighting** — the BS.1770 pre-filter applied before measuring: a high-shelf "head" boost
  plus a high-pass. Models perceived loudness. Coefficients depend on sample rate.
- **Gating** — the two-stage rule that excludes quiet passages from the Integrated measurement:
  an absolute gate at −70 LUFS, then a relative gate 10 LU below the mean of the blocks that passed
  the absolute gate (per BS.1770 — not the mean of all blocks).
- **Reset** — the action that clears the Integrated measurement (and any held maxima) so it
  starts accumulating fresh.
- **Target** — the reference loudness the meter scale is centered on (e.g. −23 LUFS for EBU,
  −14 LUFS for streaming). The bar scale is expressed in LU around this.

## Concepts

- **Pitch-following** — an Oscilloscope feature that aligns the trace to the signal's
  fundamental period each frame so a steady tone appears frozen instead of scrolling past.
  _Avoid_: triggering, sync.
- **Spectral coloring** — coloring a Module per-position by the frequency balance of that slice
  of audio rather than a single static color (MiniMeters' "RGB" color mode). Chosen primarily
  for visual appeal, secondarily as a readable cue to frequency content. _Avoid_: RGB mode
  ("RGB" is MiniMeters' UI label, not our term), frequency coloring.
