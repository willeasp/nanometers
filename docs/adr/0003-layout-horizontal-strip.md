# Layout is a flat horizontal strip of resizable, reorderable, multi-instance Module columns

The window hosts several Modules (per [0002]) and the user must be able to place, resize, and
rearrange them. We model the layout as a **flat, ordered, left-to-right strip of full-height
columns** — no vertical stacking, no recursive splits, no free-floating panels. List order *is*
left-to-right placement; reordering moves an entry. Each column has a **`width_fraction`** (not a
pixel width) so the layout scales cleanly on window resize, extending the existing instinct of
persisting logical window size.

## Multi-instance, Module-owned config

The strip holds **instances, not types** — two Waveforms at different zooms is a first-class case.
Each column entry is:

```
Column { instance_id, module_type, width_fraction, config: <opaque, Module-owned> }
```

The **host owns the list and the geometry** (order, fractions, which type sits where). Each
**Module owns its own `config` blob** — Oscilloscope window length, Waveform zoom + band
boundaries, Loudness target, etc. The host treats config as **opaque bytes** it gets from the Module
via `save_config(&self) -> Vec<u8>` and returns via `load_config(&mut self, &[u8])` — the Module
trait's persistence pair, alongside `update`/`render` ([0002]) and `on_event` ([0004]) — and never
reads the fields. This keeps the host ignorant of Module internals (same boundary discipline as
0002) and lets each Module — including the Loudness agent's — own its config schema without touching
host code.

This `layout` joins `EditorState` (which today persists only window `size`) and rides the same
nih-plug persist path into the host project, so a saved project restores its exact arrangement.

A freshly created plugin instance with no persisted state opens with an **app-default layout of
Waveform + Loudness side by side**; both the default and every Module's config are user-editable,
and each Module opens with sensible, tweakable defaults.

## Why not the alternatives

**Recursive splits (binary tree, i3/tmux-style).** Genuinely tempting for "Oscilloscope above
Waveform beside a full-height Loudness," but it's a layout *engine* — tree traversal for hit-testing
and resize, far more than a chill meter needs now. The flat strip covers the target aesthetic; if
vertical stacking is ever wanted, it's a contained extension (a column becomes a list of cells), not
a property the glossary or other Modules depend on today.

**Free 2D grid / dockable floating panels (DAW-style).** Overlap, z-order, and free hit-testing
fight the calm, glanceable identity and explode input + persistence complexity. No DJ-style meter
does this. Rejected outright.

**Singleton Modules (one of each type).** Simpler serde (a bare type string) and "add Module" = show
/hide, but it makes two Waveforms-at-different-zooms impossible and would force a painful state
migration the moment multi-instance is wanted. Rejected; the cost of carrying an instance id + config
blob per column is small.

**Pixel widths instead of fractions.** Would need recompute and could orphan/clip Modules on resize.
Fractions survive resize for free.

## Consequences

- **The persisted serde shape is a contract** the Loudness agent (and every future Module) builds
  against: `EditorState { size, layout: [Column …] }`, each column carrying a Module-owned opaque
  config. Changing it later requires a state migration for saved projects.
- **Modules must not reference each other or assume placement.** "To the right of" is not part of any
  Module's definition — placement is purely the user's layout. The glossary was scrubbed of spatial
  relationships to enforce this.
- **Hit-testing ([0004]) is trivial under this model:** a click maps to a column by x; a
  resize maps to the boundary grabbed between two columns. This simplicity is a reason the flat strip
  was chosen.
- **Geometry feeds the viewport per [0002]:** each column's `width_fraction` × surface width is the
  `viewport: Rect` handed to that Module's `render`.
