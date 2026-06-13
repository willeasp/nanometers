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

## Amendment (2026-06-13): the router lives on the RENDER thread, not the main thread

This ADR predates ADR 0008's dedicated render thread. It says "`RenderWindow::on_event` becomes the
router" — but since 0008, the `modules`, the live `layout`, the per-frame `viewports`, and the
display `scale_factor` ALL live inside `run_render_loop` on the render thread; `RenderWindow` (main
thread) owns only `params` + a resize channel. So the router **moves render-side**, where everything
it needs already lives:

- **`on_event` is a thin forwarder.** Window resize stays handled inline (it owns the persisted
  size); every other event is sent over a unified `WindowMsg` channel (mirroring the old `resize_tx`)
  to the render thread. The `PointerGrab` machine drains and runs there, once per frame, over the
  buffered events — resizes coalesce, input stays ordered. The spirit of "host owns the grab; Modules
  only capture/ignore in column-local coords" is unchanged; only the *thread* the host code runs on
  moved.
- **Column-local coords are PHYSICAL px.** The surface (and so every `viewport`) is physical px;
  baseview pointer positions are LOGICAL, so the router multiplies by `scale_factor` before
  hit-testing and before translating an event to column-local. (Matches the `Module::prepare` seam,
  which already carries `scale` for the same reason.)
- **Ungrabbed `CursorMoved` forwards to the hovered column.** The original model only spelled out
  press/grab/release; hover (a Waveform showing the dB under the cursor) needs the *ungrabbed* move
  routed to the column under the cursor. That Module mutates internal hover state and returns
  `Ignored` (hover is not a capture). This also supplies the press point: `ButtonPressed` carries no
  position in baseview, so a Module self-hit-tests a press using the last column-local `CursorMoved`
  the router forwarded.
- **Reorder preview is provisional `Column`s, not bare fractions.** Since fixed-width columns landed
  (ADR 0003 amendment), live-reflow recomputes a provisional `Vec<Column>` (fixed columns keep their
  px; flex columns keep fractions) and the render path draws from it until release. A degenerate
  reflow can leave a NaN/0 flex fraction — which serializes to JSON `null` and **fails the whole
  editor-state load** — so the provisional layout is sanitized (every flex fraction finite-positive)
  before it is ever committed via `set_layout`.

**Scope deferred to Phase F.** `LayoutResize` (dragging a divider) is only meaningful between two
*flex* columns — and the shipped default (flex Waveform + fixed Loudness) has none until multi-
instance (Phase F) can add a second flex column. The pure boundary helper (`resize_boundary_at`,
flex|flex only) is built now; the `LayoutResize` grab arm waits until it is GUI-reachable.

## Amendment (2026-06-13): the right-click context menu (Phase F3)

Multi-instance arrived: a **right-click context menu** is the host UI for adding/removing Modules
(ADR 0003 records the layout side). A right-press — only when no left grab is active — opens a flat
menu at the cursor: `Add Waveform / Add Oscilloscope / Add Loudness`, plus `Remove` when the click
was over a column. While open the menu is **modal**: it owns all pointer input, so no event reaches
a Module and no grab starts; a cursor-move tracks the hovered row, a left-press selects (committing a
`LayoutEdit` the loop applies) or — outside the panel — dismisses, and a right-press reopens
elsewhere. Dismiss is click-outside or select; there is **no Esc** path, keeping keyboard `Ignored`
for DAW passthrough (below). The menu's model + geometry are pure and tested (`menu.rs`); the Router
holds the modal state and `handle()` now returns a `Commit::{Reorder, Edit}`; a host `Overlay`
(`overlay.rs`) draws the panel + the empty-strip hint in a second full-surface `LoadOp::Load` pass.

`LayoutResize` is now **GUI-reachable** in principle — adding a second Waveform yields a flex|flex
seam — but its grab arm is still **not built**; wiring it (over the existing `resize_boundary_at`
helper) remains the open Phase F item.

**Platform note.** Keyboard events return `Ignored` so DAW transport shortcuts pass through (baseview
only honors `Captured`/`Ignored` for keyboard). `set_mouse_cursor` is `todo!()` on macOS in vendored
baseview — calling it panics — so there is no resize/grab cursor feedback this phase.
