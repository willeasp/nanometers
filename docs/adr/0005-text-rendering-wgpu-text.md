# 5. Text rendering: wgpu_text with an embedded OFL font

Date: 2026-05-30
Status: Accepted

## Context

Modules need text the renderer can't currently draw: the Loudness Module's M/S/I numeric
readouts first, then the Spectrum Analyzer's log-frequency axis labels and the Stereometer's
scale ticks. The codebase is raw wgpu 29 + baseview; `nih_plug` is pulled with only the
`standalone` feature, so none of nih-plug's text comes along — that lives in the
`nih_plug_vizia`/`iced`/`egui` integrations, which we don't use and which would replace the
hand-rolled renderer entirely. wgpu and baseview have zero font capability. Text is therefore a
new capability we add ourselves.

Three routes:

- **A full text crate** — `glyphon` (cosmic-text + swash + fontdb): real shaping, layout,
  system-font enumeration.
- **A purpose-built lighter crate** — `wgpu_text` (glyph-brush + ab_glyph): load a `.ttf`,
  rasterize into an atlas, queue sections of text.
- **Hand-rolled** — a bitmap atlas / `font8x8`, drawn as textured quads.

The rest of the renderer is deliberately hand-rolled (the Oscilloscope renderer), so taking a
dependency here breaks that ethos. But glyph rasterization — atlas packing, hinting, kerning,
subpixel AA — is the canonical GUI rabbit hole, and there is no payoff in owning it at our scale.
A further constraint settles it: we want to *choose* a typeface, not *design* one, which rules out
hand-rolled and bitmap fonts (those are one face you'd be stuck with or have to draw).

## Decision

Use **`wgpu_text`**, with a redistribution-friendly **OFL font embedded via `include_bytes!`** so
the plugin is self-contained. Per ADR 0002, text is a **Module-owned GPU pipeline**: each Module
that needs text owns its `wgpu_text` brush; the editor does not render text globally.

Rejected: **glyphon** — heavier dependency tree for shaping we don't need (no RTL, ligatures,
complex scripts, or system-font enumeration), and it lagged wgpu (it only reached wgpu 29 in
0.11, Apr 2026), a versioning hazard. **Hand-rolled / bitmap** — means designing a face rather
than choosing one, and owning the hardest part of a GUI for no benefit here.

## Consequences

- The first runtime dependency taken specifically against the hand-roll ethos. Localized to text,
  justified by the cost and risk of hand-rolling rasterization.
- `wgpu_text` is versioned in lockstep with wgpu (29.0.3 matches our 29.0.3), keeping future wgpu
  upgrades low-risk — unlike glyphon, whose lag would have pinned our wgpu version.
- `wgpu_text` draws in screen-pixel coordinates, so each Module positions its readouts inside its
  own `viewport: Rect` (clipped with `set_scissor_rect`), consistent with the per-Module viewport
  model of ADRs 0002/0003. The Loudness Module is a real Module from the start — no bottom-right
  corner interim.
- Embedding a font adds tens-to-hundreds of KB to the binary; accepted. It keeps the plugin
  self-contained — no system-font dependency, deterministic glyphs across hosts and OSes.
- The chosen face is a project-level choice; numeric readouts want a clean figure set, ideally
  tabular/monospaced so values don't jitter as digits change.
