# Waveform renders as a scrolling min/max contour, not per-column bars

The Waveform Module draws its amplitude envelope as a filled **min/max contour** per channel — a
triangle strip spanning the channel's max-curve (top) and min-curve (bottom), the silhouette a
continuous sloped polyline — and **scrolls** newest-sample-right. An optional brighter stroke traces
the silhouette. This is the geometry that replaces the removed fake "glow" (the 9-layer instanced
additive stacking on today's Oscilloscope-style line).

## Why contour, not per-column bars

At 1 px columns the two converge, but the contour gives a smooth, analog silhouette when columns are
chunky or under zoom (independent bars are flat-topped / stepped), and a clean edge for a future
bloom to read off. Cost is ~2 vertices per column per channel — trivial. Per-column bars were the
simpler alternative and were considered; the contour was chosen for the silhouette quality and the
bloom anchor.

## Outline

A brighter silhouette stroke, **Module-config toggle, default on**. DJ/DAW waveforms are typically
fill-only, so the outline is uncommon and is kept trivially disable-able and evaluated visually; it
also pre-positions the deferred bloom, which would glow off this edge.

## Anti-aliasing — per-Module, not host-wide

The sloped silhouette staircases on transients, so it needs AA — but AA is **per-Module here, not a
host-wide pass setting**. AA is three independent mechanisms: text carries its own (glyph-atlas
alpha, [0005]), MSAA smooths only geometry edges, and analytic/SDF AA is per-shader. The host shared
pass stays **single-sample** — the host owns no AA, consistent with it owning no Module internals
([0002]).

The Waveform renders its contour to its **own offscreen multisampled target**, resolves, and
composites that into its `viewport`. That target is the **same render-to-texture the future bloom
needs**, so it is the Module's eventual rendering path, not throwaway machinery. (Simpler geometry
Modules that never want an offscreen pass can instead do analytic in-shader AA; text needs neither.)

## Consequences

- The fake 9-layer additive glow (`GLOW_LAYERS`) is deleted. "Glow" returns later as a real
  multi-pass bloom reading off the outline — deferred future work, not this Module.
- Tunables — viewable window length, outline on/off, band boundaries, color-mapping strength — are
  **Module-owned config** ([0003]), dialed in on the dev-player, not fixed by this ADR.
- The contour and scroll build directly on the per-column store of [0002]/[0001] (min / max /
  mean-square per channel + 3 shared band-energy floats, associatively merged from 0.5 ms base bins
  to pixel columns at draw).
- Color is one hue per column (from the band energies, [0001]), carried on the strip vertices and
  interpolated along time.
