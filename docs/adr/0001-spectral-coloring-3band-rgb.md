# 3-band RGB spectral coloring for the Waveform, not spectral centroid

We color each Waveform column by its frequency content. We split each slice's spectrum into
three bands — low / mid / high — and map them to a color where a dominant band gives its hue
(low = red, mid = green, high = blue) and balanced/broadband content desaturates toward **white**.
This is the Traktor / Serato "spectrum waveform" model, and it's the visual the user is after.

## Why not a spectral centroid

A 1-D spectral centroid (→ a single-axis colormap) is cheaper and was tempting, but it collapses
"energy concentrated in the mids" and "energy split between the low and high extremes" to the same
value. So bass + air with no mids reads as mid/green instead of white — precisely the case the user
most wants to see. Centroid structurally cannot represent *which* bands are present; you need the
band energies themselves (3 numbers), not their average (1). Zero-crossing rate was also rejected:
too coarse, fooled by distortion/noise.

## Consequences

- Band energies come from a **GUI-side 3-band filterbank**, not an FFT. The filterbank squares
  each band's output to per-sample power and accumulates **mean-square per band into the 0.5 ms
  base bins** of [0002]'s per-column store, merged associatively to columns at draw. It is chosen
  on the merits: per-sample time resolution (color snaps to transients, where a 20–40 ms FFT
  window would smear them), zero latency, it shares the envelope's store, and 3 biquads/sample is
  cheap.
- **No shared, published spectrum.** A single app-wide FFT feeding Waveform color + Spectrum +
  Spectrogram is false DRY: it would bake a window/hop/size — a per-Module Visualization parameter
  — across the audio→GUI seam, the exact leak [0002] forbids, and no single FFT size serves a
  transient-sharp color *and* a frequency-sharp Spectrum. Each frequency-domain Module owns its
  fit-for-purpose analysis (filterbank here; purpose-sized FFTs in the future Spectrum/Spectrogram
  Modules). Reuse the FFT *utility* if perf ever demands, never a published result.
- The color DSP is **Module-internal and swappable.** If a future requirement genuinely needs more
  than 3 bands or true spectral hue, switching the Waveform's color source to an FFT is a localized
  change inside this Module — not a re-architecture.
- "White = broadband" must come from the *mapping* (saturation = spectral imbalance), not from
  naïvely summing band energies into (R,G,B) — naïve additive makes bass+air magenta, not white.
- Band boundaries (≈250 Hz / ≈4 kHz to start), the palette, and how hard "white" kicks in are
  visual-tuning parameters, dialed in on real audio via the dev-player — not fixed by this ADR.
