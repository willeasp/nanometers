# Phase E — Input routing (host PointerGrab) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route pointer/keyboard events to the right owner — host (reorder a column, resize a flex boundary) or Module (reset Loudness, hover a Waveform) — via a single host-owned pointer-grab state machine (ADR 0004).

**Architecture:** ADR 0004 predates the dedicated render thread (ADR 0008). Today the `modules`, the live `layout`, the per-frame `viewports`, and `scale_factor` ALL live on the render thread inside `run_render_loop`; `RenderWindow` (main thread) owns only `params` + a resize channel. So the router **moves to the render thread**: `on_event` becomes a thin forwarder over a channel (mirroring `resize_tx`), and the `PointerGrab` machine runs render-side where everything it needs already lives. Spirit of 0004 intact (host owns grabs; Modules only return `Captured`/`Ignored` in column-local coords) — only the *location* changes. This needs an ADR 0004 amendment.

**Tech Stack:** Rust, baseview events (vendored), wgpu viewports, serde-persisted `EditorState`, nih-plug.

---

## Resolved scope decisions (grill, 2026-06-13)

1. **Reorder feel → live-reflow NOW.** While dragging, the remaining columns reflow under the cursor to preview the drop slot (ADR 0004 as written). E2 recomputes a provisional layout per mouse-move and renders from it; commit on release.
2. **LayoutResize grab → DEFERRED to Phase F.** The shipped default (flex Waveform | fixed Loudness) has zero draggable flex|flex boundaries; a second flex column needs multi-instance (Phase F). E1 still ships the pure `resize_boundary_at` helper (documents the flex|flex rule, TDD'd); E2's grab is `None` / `LayoutReorder` / `Module` only — no `LayoutResize` arm.
3. **Waveform hover-dB → routing NOW, dB text DEFERRED.** E2 forwards ungrabbed `CursorMoved` to the hovered column; the Waveform stores hovered-x + peak dB (cheap, no GPU text). The on-screen readout rides a later text-brush follow-up.
4. **Loudness reset → click the I caption.** Left press on the Integrated bar's caption area → `LoudnessDsp::reset()` → `Captured`. No new geometry.

---

## File structure

- `apps/nano-plugin/src/layout.rs` — gains **pure** hit-testing helpers (`column_index_at`, `resize_boundary_at`, `reorder_target`, `apply_reorder`, `sanitize_layout`) + their unit tests. No threads, no GPU — the TDD core of this phase.
- `apps/nano-plugin/src/input.rs` — **new file**: the `PointerGrab` enum + `Router` struct (the state machine). Render-side. Holds transient drag state; mutates `layout` + `modules`; commits via `EditorState::set_layout`. Pure-ish (takes slices + a commit callback) so its non-GPU logic is unit-testable.
- `apps/nano-plugin/src/editor.rs` — `RenderWindow` gains an input forwarder; `run_render_loop` drains a unified `WindowMsg` channel, runs the `Router` over buffered inputs each frame, and recomputes viewports from the (possibly mutated) layout. Blanket-`Captured` fixed.
- `apps/nano-plugin/src/module/loudness.rs` — `on_event` consumes a click on the I-caption → `LoudnessDsp::reset()` → `Captured`.
- `apps/nano-plugin/src/module/waveform/mod.rs` — `on_event` stores hovered physical-x + peak dB on `CursorMoved`, clears on `CursorLeft`; returns `Ignored` (hover is internal mutation, not capture).
- `docs/adr/0004-input-routing-pointer-grab.md` — amendment: router location (render thread), column-local = PHYSICAL px, ungrabbed-hover forwarding, provisional widths-not-fractions, LayoutResize deferred.

---

## Task E0: Plumbing — unified WindowMsg channel + EditorState into the render loop + un-blanket the capture

**Files:**
- Modify: `apps/nano-plugin/src/editor.rs` (channel type, `on_event`, `run_render_loop` signature + drain, `RenderWindow` struct)

No new behavior yet — pure refactor that makes E2 possible. The render loop already drains a coalescing resize channel; we widen it to carry input too, **without** letting resize-coalescing eat mouse events.

- [ ] **Step 1: Define `WindowMsg` and switch the channel type.**

In `editor.rs`, near the `RenderWindow` struct:

```rust
/// Main thread → render thread. Resizes coalesce (only the latest matters); input events must NOT
/// coalesce (every press/move/release counts), so they ride the same channel and the render loop
/// splits them on drain. `baseview::Event` is plain data (no Rc/raw ptr) → Send across the seam.
enum WindowMsg {
    Resize { w: u32, h: u32, scale: f32 },
    Input(baseview::Event),
}
```

Change `RenderWindow.resize_tx: Sender<(u32, u32, f32)>` → `msg_tx: Sender<WindowMsg>`. Change the channel creation in `create()` from `channel::<(u32,u32,f32)>()` → `channel::<WindowMsg>()`, and the `run_render_loop` param `resize_rx: Receiver<(u32,u32,f32)>` → `msg_rx: Receiver<WindowMsg>`.

- [ ] **Step 2: Pass the `EditorState` into the render loop so the Router can commit.**

`run_render_loop` currently can persist nothing. Add a param `state: Arc<EditorState>` (clone `params.editor_state` in `create()` before the thread spawn — `params` isn't moved into the loop today, only `shared` is). The loop needs it to call `state.set_layout(...)` on drag-commit.

- [ ] **Step 3: Make `layout` mutable in the loop and forward input in `on_event`.**

`run_render_loop`'s `layout: Vec<Column>` → `mut layout`. In `RenderWindow::on_event`, keep the resize branch (now sending `WindowMsg::Resize {…}`), and add: forward every other event as `WindowMsg::Input(event.clone())`. Fix the blanket capture — return `Ignored` for keyboard so DAW shortcuts (spacebar transport) still reach the host (baseview only honors Captured/Ignored for keyboard, per `event.rs:140-148`):

```rust
fn on_event(&mut self, _w: &mut baseview::Window, event: baseview::Event) -> baseview::EventStatus {
    match &event {
        baseview::Event::Window(baseview::WindowEvent::Resized(info)) => {
            self.params.editor_state.size.store((
                info.logical_size().width.round() as u32,
                info.logical_size().height.round() as u32,
            ));
            let _ = self.msg_tx.send(WindowMsg::Resize {
                w: info.physical_size().width,
                h: info.physical_size().height,
                scale: info.scale() as f32,
            });
            baseview::EventStatus::Captured
        }
        baseview::Event::Keyboard(_) => {
            // Pass keyboard to the DAW (transport shortcuts) — we render no param GUI yet.
            baseview::EventStatus::Ignored
        }
        _ => {
            let _ = self.msg_tx.send(WindowMsg::Input(event.clone()));
            baseview::EventStatus::Captured
        }
    }
}
```

- [ ] **Step 4: Split the drain in `run_render_loop` — coalesce resize, buffer input in order.**

Replace the existing resize drain:

```rust
let mut pending_resize = None;
let mut inputs: Vec<baseview::Event> = Vec::new();
while let Ok(msg) = msg_rx.try_recv() {
    match msg {
        WindowMsg::Resize { w, h, scale } => pending_resize = Some((w, h, scale)),
        WindowMsg::Input(ev) => inputs.push(ev),
    }
}
if let Some((w, h, scale)) = pending_resize {
    surface_config.width = w.max(1);
    surface_config.height = h.max(1);
    surface.configure(&device, &surface_config);
    scale_factor = scale;
}
```

Leave `inputs` unused for now (E2 consumes it). The router call slots in here in E2, AFTER the resize is applied (so it hit-tests against the current surface size) and BEFORE viewports are computed for render.

- [ ] **Step 5: `cargo check` + `cargo test` (the existing 15 tests still pass).**

Run: `cargo check -p nano-plugin && cargo test -p nano-plugin`
Expected: compiles; all existing tests pass (no behavior change yet).

- [ ] **Step 6: Commit.**

```
refactor(input): unify the main→render channel into WindowMsg; route keyboard to the DAW

Widens resize_tx into a WindowMsg channel carrying input too (resizes coalesce, input
stays ordered), threads EditorState into the render loop for later drag-commit, and stops
blanket-capturing keyboard so DAW transport shortcuts pass through. No behavior yet — sets
up the render-side router (ADR 0004, amended: the router lives render-side since modules do).
```

---

## Task E1: Pure hit-testing + reorder + sanitize helpers (TDD)

**Files:**
- Modify: `apps/nano-plugin/src/layout.rs` (helpers + `#[cfg(test)]` cases)

All pure functions over `&[Column]` / `&[Rect]` and a physical-px `x`. No threads, no GPU — strict red→green.

- [ ] **Step 1: Write the failing tests** in `layout.rs`'s `mod tests`:

```rust
#[test]
fn column_index_at_maps_x_to_the_containing_rect() {
    let vp = viewports(&cols(&[0.5, 0.5]), 800.0, 600.0, 1.0); // [0..400), [400..800)
    assert_eq!(column_index_at(&vp, 10.0), Some(0));
    assert_eq!(column_index_at(&vp, 399.9), Some(0));
    assert_eq!(column_index_at(&vp, 400.0), Some(1));
    assert_eq!(column_index_at(&vp, 799.9), Some(1));
    assert_eq!(column_index_at(&vp, 900.0), None); // past the surface
}

#[test]
fn resize_boundary_only_between_two_flex_columns() {
    // flex | flex: the seam IS draggable.
    let flexflex = cols(&[0.5, 0.5]);
    let vp = viewports(&flexflex, 800.0, 600.0, 1.0); // seam at 400
    assert_eq!(resize_boundary_at(&flexflex, &vp, 402.0, 6.0), Some(0));
    assert_eq!(resize_boundary_at(&flexflex, &vp, 420.0, 6.0), None, "outside gutter");

    // flex | fixed: the fixed column owns its width → NOT draggable (ADR 0003 amendment).
    let flexfixed = vec![
        Column::new(0, module_type::WAVEFORM, 1.0),
        Column::fixed(1, module_type::LOUDNESS, 200.0),
    ];
    let vp2 = viewports(&flexfixed, 800.0, 600.0, 1.0); // seam at 600
    assert_eq!(resize_boundary_at(&flexfixed, &vp2, 600.0, 6.0), None);
}

#[test]
fn reorder_target_counts_other_midpoints_left_of_cursor() {
    let vp = viewports(&cols(&[0.34, 0.33, 0.33]), 900.0, 600.0, 1.0);
    // mids ≈ 153, 459, 762. Drag col 0 (A): cursor just right of B's mid → target slot 1.
    assert_eq!(reorder_target(&vp, 0, 460.0), 1);
    // cursor past C's mid → slot 2 (drop at the end).
    assert_eq!(reorder_target(&vp, 0, 800.0), 2);
    // cursor near the left edge → stays slot 0.
    assert_eq!(reorder_target(&vp, 0, 10.0), 0);
}

#[test]
fn apply_reorder_moves_and_shifts() {
    let c = cols(&[0.3, 0.3, 0.4]); // ids 0,1,2
    let moved = apply_reorder(&c, 0, 2); // A to the end
    assert_eq!(moved.iter().map(|c| c.instance_id).collect::<Vec<_>>(), vec![1, 2, 0]);
}

#[test]
fn sanitize_replaces_nonfinite_or_nonpositive_flex_fractions() {
    let mut c = cols(&[f32::NAN, 0.0, -1.0, 0.5]);
    sanitize_layout(&mut c);
    assert!(c.iter().all(|c| c.width_fraction.is_finite() && c.width_fraction > 0.0));
    assert_eq!(c[3].width_fraction, 0.5, "a good fraction is left alone");
}

#[test]
fn sanitized_layout_survives_a_serde_round_trip() {
    // The reason sanitize exists: serde_json writes f32 NaN as `null`, and `null` FAILS to
    // deserialize back into f32 — one NaN fraction would brick the whole editor-state load.
    let mut c = cols(&[f32::NAN, 0.5]);
    sanitize_layout(&mut c);
    let json = serde_json::to_string(&c).unwrap();
    let back: Vec<Column> = serde_json::from_str(&json).unwrap();
    assert_eq!(back.len(), 2);
}
```

- [ ] **Step 2: Run them, watch them fail** (functions don't exist).

Run: `cargo test -p nano-plugin --lib layout::tests`
Expected: FAIL — `cannot find function column_index_at` etc.

- [ ] **Step 3: Implement the helpers** in `layout.rs` (above the `#[cfg(test)]`):

```rust
/// Smallest flex fraction `sanitize_layout` will pin a degenerate value to — keeps a column
/// visible and, crucially, finite-positive so it can't serialize to a load-breaking JSON `null`.
const MIN_FLEX_FRACTION: f32 = 0.05;

/// The column whose viewport contains physical-px `x` (columns are full-height, so x alone
/// decides). `None` if x is past every rect — including a column clamped to zero width in a
/// too-narrow window. Viewports tile gap-free, so the first containing rect is the answer.
pub fn column_index_at(viewports: &[Rect], x: f32) -> Option<usize> {
    viewports
        .iter()
        .position(|r| r.w > 0.0 && x >= r.x && x < r.x + r.w)
}

/// The draggable resize boundary under physical-px `x`, within `gutter_px` of a column seam.
/// ONLY a seam between two FLEXING columns is draggable: a fixed column owns its width (ADR 0003
/// amendment), so flex|fixed and fixed|fixed seams return `None`. Returns the LEFT column's index.
/// NOTE: the shipped default layout (flex Waveform | fixed Loudness) has no such seam — resize
/// becomes reachable only with two flex columns (Phase F multi-instance).
pub fn resize_boundary_at(
    cols: &[Column],
    viewports: &[Rect],
    x: f32,
    gutter_px: f32,
) -> Option<usize> {
    (0..cols.len().saturating_sub(1)).find(|&i| {
        let seam = viewports[i].x + viewports[i].w; // == viewports[i + 1].x (gap-free tiling)
        (x - seam).abs() <= gutter_px
            && cols[i].fixed_width_px.is_none()
            && cols[i + 1].fixed_width_px.is_none()
    })
}

/// The slot the dragged column should occupy if dropped at physical-px `cursor_x`: the count of
/// OTHER columns whose midpoint sits left of the cursor. The index is in the post-removal array,
/// so it pairs directly with [`apply_reorder`]`(cols, dragged, reorder_target(..))`.
pub fn reorder_target(viewports: &[Rect], dragged: usize, cursor_x: f32) -> usize {
    viewports
        .iter()
        .enumerate()
        .filter(|&(i, r)| i != dragged && cursor_x > r.x + r.w * 0.5)
        .count()
}

/// Move the column at `from` to index `to` (clamped), shifting the rest; returns a new Vec.
pub fn apply_reorder(cols: &[Column], from: usize, to: usize) -> Vec<Column> {
    let mut v = cols.to_vec();
    let c = v.remove(from);
    v.insert(to.min(v.len()), c);
    v
}

/// Clamp every FLEX column's `width_fraction` to a finite, strictly-positive value. A degenerate
/// resize/reflow can leave a NaN/0/negative fraction; serde_json writes NaN as `null` and `null`
/// fails to deserialize into f32 — so one bad fraction would brick the next editor-state load.
/// Fixed columns' fractions are ignored by `viewports`, so they're left untouched.
pub fn sanitize_layout(cols: &mut [Column]) {
    for c in cols.iter_mut() {
        if c.fixed_width_px.is_none() && !(c.width_fraction.is_finite() && c.width_fraction > 0.0) {
            c.width_fraction = MIN_FLEX_FRACTION;
        }
    }
}
```

- [ ] **Step 4: Run them, watch them pass.**

Run: `cargo test -p nano-plugin --lib layout::tests`
Expected: PASS — all old + 6 new.

- [ ] **Step 5: Commit.**

```
feat(layout): pure hit-test/reorder/sanitize helpers for the pointer-grab router

column_index_at, resize_boundary_at (flex|flex only — fixed columns aren't user-draggable),
reorder_target + apply_reorder, and sanitize_layout (a NaN fraction serializes to JSON null
and fails the whole editor-state load — never let one reach set_layout). Pure, TDD'd; the
render-side Router (E2) drives them.
```

---

## Task E2: The PointerGrab router (render-side state machine)

**Files:**
- Create: `apps/nano-plugin/src/input.rs`
- Modify: `apps/nano-plugin/src/lib.rs` (`mod input;`)
- Modify: `apps/nano-plugin/src/editor.rs` (run the router over `inputs` each frame)

The machine lives render-side where `modules` + `layout` live. Press decides the grab once (no `LayoutResize` this phase — see scope decision 1); grabbed moves/release route to the owner; ungrabbed moves forward to the hovered column (the hover path). Release commits a reorder.

- [ ] **Step 1: Write the failing test** for the pure decision logic in `input.rs`. The router's GPU-free core is "given a press at x with this layout, what grab results, and what does a release do to the order" — testable with a fake module-hit closure:

```rust
#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{module_type, Column};

    fn two_flex() -> Vec<Column> {
        vec![
            Column::new(0, module_type::WAVEFORM, 0.5),
            Column::new(1, module_type::WAVEFORM, 0.5),
        ]
    }

    #[test]
    fn body_press_on_an_ignoring_module_begins_a_reorder() {
        let cols = two_flex();
        let vp = crate::layout::viewports(&cols, 800.0, 600.0, 1.0);
        let mut grab = PointerGrab::None;
        // Module ignores → body press → reorder grab of the column under x=100 (col 0).
        decide_press(&mut grab, &cols, &vp, 100.0, |_idx, _local_x| EventStatus::Ignored);
        assert!(matches!(grab, PointerGrab::LayoutReorder { instance_id: 0, .. }));
    }

    #[test]
    fn press_on_a_capturing_module_begins_a_module_grab() {
        let cols = two_flex();
        let vp = crate::layout::viewports(&cols, 800.0, 600.0, 1.0);
        let mut grab = PointerGrab::None;
        decide_press(&mut grab, &cols, &vp, 500.0, |_idx, _local_x| EventStatus::Captured);
        assert!(matches!(grab, PointerGrab::Module { instance_id: 1 }));
    }

    #[test]
    fn reorder_release_permutes_the_order_by_cursor_x() {
        let cols = two_flex();
        let vp = crate::layout::viewports(&cols, 800.0, 600.0, 1.0);
        // Dragging col 0, releasing past col 1's midpoint → [1, 0].
        let new = reorder_release(&cols, &vp, 0, 700.0);
        assert_eq!(new.iter().map(|c| c.instance_id).collect::<Vec<_>>(), vec![1, 0]);
    }
}
```

- [ ] **Step 2: Run, watch fail** (`input` module / functions don't exist).

Run: `cargo test -p nano-plugin --lib input::tests`
Expected: FAIL — unresolved module `input`.

- [ ] **Step 3: Create `input.rs`** with the enum + the pure decision helpers + the event-driven `Router`. The pure helpers (`decide_press`, `reorder_release`) are what the tests above pin; `Router::handle` wires them to live `modules`/`layout`/`state` and is verified in the GUI (integration, no unit seam — it needs real `Box<dyn Module>`s and a `Queue`).

```rust
//! The host-owned pointer-grab state machine (ADR 0004, amended: render-side).
//!
//! baseview delivers events on the MAIN thread; this runs on the RENDER thread (where `modules`
//! and `layout` live), fed buffered `baseview::Event`s by `run_render_loop`. The grab is decided
//! once on press and owns every move/release until the button comes up — so a drag sticks to its
//! owner even as the cursor crosses column boundaries. Modules only ever see column-local PHYSICAL
//! coords and return `Captured`/`Ignored`; they never learn about layout.

use crate::layout::{
    apply_reorder, column_index_at, reorder_target, sanitize_layout, Column,
};
use crate::module::{EventStatus, Module, Rect};

/// Which owner holds the pointer until mouse-up (ADR 0004). `LayoutResize` is deferred to Phase F
/// (no draggable flex|flex boundary exists until multi-instance) — its arm isn't built here.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PointerGrab {
    None,
    LayoutReorder { instance_id: u64, grab_dx: f32 },
    Module { instance_id: u64 },
}

/// Decide the grab on a body/module press at physical-px `x`. `hit(column_index, local_x)` offers
/// the press to that Module in column-local coords and reports whether it captured. A `Captured`
/// → `Module` grab; an `Ignored` body press → `LayoutReorder`.
pub fn decide_press(
    grab: &mut PointerGrab,
    cols: &[Column],
    viewports: &[Rect],
    x: f32,
    hit: impl FnOnce(usize, f32) -> EventStatus,
) {
    let Some(idx) = column_index_at(viewports, x) else { return };
    let local_x = x - viewports[idx].x;
    match hit(idx, local_x) {
        EventStatus::Captured => *grab = PointerGrab::Module { instance_id: cols[idx].instance_id },
        EventStatus::Ignored => {
            *grab = PointerGrab::LayoutReorder { instance_id: cols[idx].instance_id, grab_dx: local_x }
        }
    }
}

/// The reordered columns when a `LayoutReorder` of the column currently at `dragged` releases at
/// physical-px `cursor_x`. Pure: caller commits the result.
pub fn reorder_release(cols: &[Column], viewports: &[Rect], dragged: usize, cursor_x: f32) -> Vec<Column> {
    let to = reorder_target(viewports, dragged, cursor_x);
    let mut new = apply_reorder(cols, dragged, to);
    sanitize_layout(&mut new);
    new
}

/// The render-side router. Owns transient drag state; the loop calls `handle` per buffered event,
/// then reads back `modules`/`layout` for the frame. (`Router::handle` is integration-tested in
/// the GUI — it needs live `Box<dyn Module>`s; the pure decisions above carry the unit coverage.)
pub struct Router {
    grab: PointerGrab,
    /// `ButtonPressed`/`Released` carry no position (baseview), so we track the last `CursorMoved`.
    last_cursor: Option<(f32, f32)>,
}
// `Router::new`, `handle(&mut self, event, &mut modules, &mut layout, scale, commit)` — built in
// Step 4 against the editor wiring.
```

- [ ] **Step 4: Run the pure tests, watch pass; then wire `Router::handle` in `editor.rs`.**

Run: `cargo test -p nano-plugin --lib input::tests` → PASS.

Then in `run_render_loop`, after the resize is applied and before viewports are computed for render, run the router over the buffered `inputs`. `Router::handle` converts logical→physical (`x = position.x as f32 * scale_factor`), routes by grab state, calls `Module::on_event` with a column-local `Rect` + a translated event.

**Live-reflow (resolved: build now).** While a `LayoutReorder` grab is active, each `CursorMoved` recomputes a *provisional* layout — `apply_reorder(committed, dragged, reorder_target(viewports, dragged, cursor_x))`, then `sanitize_layout` — and the render path draws from THAT provisional layout (the columns slide to preview the drop slot). The committed `layout` is untouched until release; the Router holds the provisional copy. On `ButtonReleased`, the provisional becomes committed: `state.set_layout(provisional.clone())` and `layout = provisional` (viewports follow next frame). So `run_render_loop` keeps two layouts while a reorder is live: the committed one and the Router's provisional; render uses provisional-if-dragging else committed. Keep the dragged column's index tracked by `instance_id` (the array index shifts as others reflow).

- [ ] **Step 5: `cargo check` + build + GUI verify.**

Run: `cargo check -p nano-plugin` then `cargo run --features dev-player --bin nanometers -- --backend dummy` (with `NANO_DEV_FILE` set). Drag the Loudness column across the Waveform and release → the two swap order and the swap persists across a reopen. Report the actual observed behavior.

- [ ] **Step 6: Commit.**

```
feat(input): render-side PointerGrab router — reorder columns by drag (ADR 0004, amended)

The grab machine runs on the render thread (modules + layout live there since ADR 0008), fed
buffered events over the WindowMsg channel. Press decides the grab once; a body press on an
ignoring module begins a LayoutReorder that commits the new order to EditorState on release.
LayoutResize is deferred to Phase F (no draggable flex|flex boundary exists until multi-instance).
```

---

## Task E3: Loudness reset on the I-caption click

**Files:**
- Modify: `apps/nano-plugin/src/module/loudness.rs` (`on_event`)

- [ ] **Step 1: Write the failing test** in `loudness.rs`'s test module — the pure hit-test "is this column-local point on the Integrated caption?" (the geometry helper), independent of GPU:

```rust
#[test]
fn integrated_caption_hit_test_covers_the_i_column_bottom() {
    // A press in the bottom caption strip under the third (Integrated) bar hits the reset zone;
    // a press up in the bars does not. (Exact band math mirrors `prepare`'s caption layout.)
    let vp = Rect { x: 0.0, y: 0.0, w: 160.0, h: 400.0 };
    assert!(is_on_integrated_caption(vp, /*local_x*/ 140.0, /*local_y*/ 390.0, /*scale*/ 1.0));
    assert!(!is_on_integrated_caption(vp, 140.0, 20.0, 1.0));
}
```

- [ ] **Step 2: Run, watch fail** (`is_on_integrated_caption` doesn't exist).

Run: `cargo test -p nano-plugin --lib module::loudness`
Expected: FAIL.

- [ ] **Step 3: Implement** `is_on_integrated_caption(viewport, local_x, local_y, scale) -> bool` (derive the I-bar's x band + the caption strip's y band from the same `hlayout()`/`caption_h()` knobs `prepare` uses), then consume it in `on_event`:

```rust
fn on_event(&mut self, event: &baseview::Event, viewport: Rect) -> EventStatus {
    use baseview::{Event, MouseButton, MouseEvent};
    // ButtonPressed carries no position; the router only forwards a press to the column it
    // hit-tested, and translates it to column-local — but we still need the point. The router
    // hands us a CursorMoved-tracked local point via the event it forwards (see editor wiring);
    // here we match a left press and use the router-translated position.
    if let Event::Mouse(MouseEvent::ButtonPressed { button: MouseButton::Left, .. }) = event {
        if /* router-supplied local point on the I-caption */ false {
            self.dsp.reset();
            return EventStatus::Captured;
        }
    }
    EventStatus::Ignored
}
```

> **Wiring note (resolve in grill):** `ButtonPressed` has no position, so the *Module* can't self-hit-test a press without the router supplying the point. Two clean options: (a) the router only forwards the press to the hit column AND, because it already computed `local_x/local_y`, the Module re-reads the last cursor it was sent via a prior `CursorMoved` (Modules see those too); or (b) extend the Module trait's `on_event` to take the column-local point alongside the event. **Recommendation: (a)** — no trait change; the router forwards `CursorMoved` to the hovered column already (hover path), so the Module has the latest local point when the press arrives. Pin this in the grill before coding Step 3.

- [ ] **Step 4: Run, watch pass; build; GUI verify.**

Run: `cargo test -p nano-plugin --lib module::loudness` → PASS. Then build the standalone and click the I caption → Integrated readout snaps back to idle and re-integrates. Report actual behavior.

- [ ] **Step 5: Commit.**

```
feat(loudness): reset Integrated on an I-caption click (ADR 0004)

on_event captures a left press on the Integrated caption and calls LoudnessDsp::reset();
everything else returns Ignored so the host can still turn a body press into a reorder.
```

---

## Task E4: Waveform hover state (routing proven; dB text deferred)

**Files:**
- Modify: `apps/nano-plugin/src/module/waveform/mod.rs` (`on_event`)

Per scope decision 2: store the hovered point + peak dB on `CursorMoved`, clear on `CursorLeft`; do NOT render text yet. This proves the ungrabbed-hover routing end-to-end without a text brush.

- [ ] **Step 1: Write the failing test** — hover sets state, leave clears it, and `on_event` returns `Ignored` (hover is never a capture):

```rust
#[test]
fn hover_records_peak_db_under_the_cursor_and_leave_clears_it() {
    let m = /* a WaveformModule with a known display_cols envelope */;
    // CursorMoved at a local x over a -6 dBFS column → Some(db≈-6); returns Ignored.
    // CursorLeft → None.
}
```

(Build the module with a tiny synthetic `display_cols` so the dB lookup is deterministic; assert on `m.hover` being `Some`/`None` and the returned `EventStatus::Ignored`.)

- [ ] **Step 2: Run, watch fail.**

Run: `cargo test -p nano-plugin --lib module::waveform`
Expected: FAIL.

- [ ] **Step 3: Implement** a `hover: Option<HoverReadout>` field + `on_event`: on `CursorMoved`, index `display_cols` by column-local PHYSICAL x (one bin per physical px — this is why column-local must be physical; write that into the trait doc), read the peak from that bin's envelope, convert to dBFS; on `CursorLeft`, set `None`. Return `Ignored` always.

- [ ] **Step 4: Run, watch pass.**

Run: `cargo test -p nano-plugin --lib module::waveform` → PASS.

- [ ] **Step 5: Commit.**

```
feat(waveform): record hovered peak-dB under the cursor (routing only; text deferred)

on_event indexes display_cols by column-local physical x and stores the peak dB; CursorLeft
clears it. Returns Ignored — hover is internal state, not a capture. The on-screen dB readout
lands when the Waveform gets a wgpu_text brush (separate follow-up).
```

---

## Task E5: Docs — ADR 0004 amendment + stale-path reconciliation

**Files:**
- Modify: `docs/adr/0004-input-routing-pointer-grab.md` (amendment block)
- Modify: `CLAUDE.md` (file-layout block is stale — names `nanometers/src/...`, the tree is now `apps/nano-plugin/src/...`)
- Modify: `docs/superpowers/plans/2026-05-30-module-host-and-modules.md` (mark Phase E status; note Resize deferred)

- [ ] **Step 1: Append an amendment to ADR 0004** capturing what the build proved:
  - The router lives on the **render thread** (ADR 0004 predates ADR 0008's render thread; `on_event` is a forwarder over the `WindowMsg` channel).
  - Column-local coords are **PHYSICAL px** (the surface is physical; baseview positions are logical and get `× scale_factor` render-side).
  - Ungrabbed `CursorMoved` forwards to the hovered column (the hover path ADR 0004 didn't spell out).
  - Reorder preview carries **provisional `Column`s (widths, not just fractions)** — fixed columns keep px during the drag.
  - **`LayoutResize` is deferred to Phase F** — no draggable flex|flex boundary exists until multi-instance; the pure `resize_boundary_at` helper is in place.
  - Keyboard events return `Ignored` (DAW transport passthrough); `set_mouse_cursor` is `todo!()` on macOS so there's no resize-cursor feedback this phase.

- [ ] **Step 2: Fix the stale `CLAUDE.md` file-layout block** to the workspace tree (`apps/nano-plugin/src/{lib,editor,input,layout}.rs`, `crates/nano-dsp`, etc.).

- [ ] **Step 3: Commit.**

```
docs: amend ADR 0004 for the render-side router; reconcile stale paths

Records what Phase E proved — router on the render thread, column-local = physical px, hover
forwarding, provisional-widths reorder, LayoutResize deferred to Phase F — and fixes CLAUDE.md's
file-layout block (still naming the pre-workspace nanometers/src/ tree).
```

---

## Self-review checklist (run before handing off)

- **Spec coverage:** ADR 0004's three owners — host-resize (deferred, helper in place + documented), host-reorder (E2), Module interior (E3 reset, E4 hover). Press-once-decide, grab-until-up, column-local coords, Ignored-enables-reorder — all in E2/E3.
- **Type consistency:** `module::EventStatus` (Captured/Ignored) is the Module return; `baseview::EventStatus` (Captured/Ignored/AcceptDrop) is the window return — never crossed. `PointerGrab` has no `LayoutResize` arm this phase (deferred), matching the ADR amendment.
- **Traps encoded:** no-position press → `last_cursor` tracking; logical→physical `× scale`; `CursorLeft` mid-drag must NOT end a grab (a grab ends only on `ButtonReleased`); keyboard → `Ignored`; never call `set_mouse_cursor` (panics on macOS); NaN fraction → `sanitize_layout` before any `set_layout`.
- **No placeholder steps:** the only deliberately-open items are the three grill forks at the top and the two wiring notes (E2 Step 4 live-reflow, E3 Step 3 press-point source) — resolve all in the grill before coding the affected task.
