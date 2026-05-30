# Input routing: host-owned pointer-grab state machine, Modules only capture/ignore

The Module-host must route pointer and window events to three different owners: the **host**
(resize a column boundary, reorder a column) and the **Modules** (interior interactions — click a
Waveform for a dB readout, click a Loudness Module to reset, drag a future control). All of these
can require a drag to keep tracking the same target even as the cursor moves across column
boundaries. We put a single **pointer-grab state machine in the host**; Modules stay ignorant of
layout and only ever report whether they captured an event.

## The model

`RenderWindow::on_event` (today: window-resize only) becomes the router. Window-level events
(surface resize) stay host-only. Pointer events are dispatched through one grab:

```
enum PointerGrab {
    None,
    LayoutResize  { boundary },                 // host: dragging a divider between two columns
    LayoutReorder { instance_id, grab_dx },     // host: dragging a column to a new slot
    Module        { instance_id },              // module: forwarded until mouse-up
}
```

- **On press**, the grab is decided once: pointer in the few-pixel **resize gutter** at a column
  boundary → `LayoutResize`; otherwise the event is offered to the column under the cursor (mapped by
  x, in column-local coords) and if the Module returns `Ignored`, a body press becomes
  `LayoutReorder`; if it returns `Captured`, the grab is `Module`.
- **While grabbed**, every move/up event goes to the grab owner regardless of cursor x. Host grabs
  drive layout; Module grabs forward in column-local coords.
- **On release**, the grab returns to `None`; a `LayoutReorder` commits the new order and
  width fractions into `EditorState.layout` ([0003]).

The Module trait gains exactly one method; the grab lives entirely in the host:

```rust
fn on_event(&mut self, event: &Event, viewport: Rect) -> EventStatus;  // Captured | Ignored
```

## Reorder is live-reflow

During a `LayoutReorder` drag, the dragged column floats under the cursor and the remaining columns
**reflow live** to preview the drop slot (browser-tab / MiniMeters feel), committing on release.
This is pure host viewport math (provisional width fractions recomputed per mouse-move) — no Module
involvement, no trait change.

## Why this shape

- **One mechanism covers both drag captures.** The user-motivating case — *see the column move
  while rearranging* — is the host's `LayoutReorder` grab. A future draggable control inside a
  Module (e.g. a Loudness target slider that must keep tracking when the cursor leaves the column)
  is the `Module` grab. Both are the same "who owns the pointer until mouse-up" question, so building
  the host grab gets Module capture nearly free.
- **Modules never learn about layout.** They return `Captured`/`Ignored` and receive column-local
  coordinates; reordering, resizing, and reflow are invisible to them. Same boundary discipline as
  0002/0003 — Modules don't reference each other or their placement.
- **Press-time decision avoids the click-vs-resize ambiguity.** The resize gutter is checked before
  the Module sees the event; everything inboard is the Module's. The grab is fixed at press, so a
  drag can't change owners mid-gesture.

## Why not the alternatives

**Snap-on-release reorder** (dragged column floats, others snap only at drop) was rejected — live
reflow is the better feel the user asked for and the cost is per-move fraction math already being
done.

**Per-Module event capture without a host grab** can't express cross-column drags (reorder, or a
slider whose pointer leaves the column) — the moment the cursor crosses a boundary, x-mapping would
hand the event to the wrong Module. The host grab is what makes drags stick to their owner.

## Consequences

- The host carries transient drag state (`PointerGrab` + provisional layout during reflow) that is
  **not persisted** — only the committed `layout` lands in `EditorState`.
- `EventStatus::Ignored` from a Module is meaningful: it's the fallback signal that lets a body press
  become a reorder. Modules must return `Ignored` for events they don't consume, not blanket-capture.
