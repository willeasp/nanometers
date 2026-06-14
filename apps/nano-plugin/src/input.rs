//! The host-owned pointer-grab state machine (ADR 0004, amended: render-side).
//!
//! baseview delivers events on the MAIN thread; this runs on the RENDER thread (where `modules`
//! and `layout` live since ADR 0008), fed buffered `baseview::Event`s by `run_render_loop`. The
//! grab is decided once on press and owns every move/release until the button comes up — so a drag
//! sticks to its owner even as the cursor crosses column boundaries. Modules only ever see
//! column-local PHYSICAL coords and return `Captured`/`Ignored`; they never learn about layout.
//!
//! Reorder is LIVE-REFLOW: while a `LayoutReorder` grab is active each move recomputes a
//! provisional `Vec<Column>` (the strip re-tiles to preview the drop slot) and the render path
//! draws from it; the committed layout changes only on release. Hit-testing stays against the
//! stable COMMITTED viewports, so the swap points don't shift under the cursor mid-drag.

use crate::editor::LayoutEdit;
use crate::layout::{
    apply_reorder, column_index_at, reorder_target, resize_boundary_at, sanitize_layout, Column,
};
use crate::menu::{menu_item_at, menu_rect, MenuItem, MenuModel};
use crate::module::{EventStatus, Module, Rect};

/// How close (physical px) a press must land to a flex|flex seam to grab it for a resize instead of
/// passing to the column. Matches the Phase E `resize_boundary_at` tests' gutter.
const RESIZE_GUTTER_PX: f32 = 6.0;

/// Which owner holds the pointer until mouse-up (ADR 0004). `LayoutResize` drags the seam between two
/// FLEX columns to retrade their widths (Phase F4) — only reachable once multi-instance (F3) has put
/// two flex columns side by side, since the default flex|fixed seam isn't draggable.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PointerGrab {
    None,
    LayoutReorder { instance_id: u64 },
    LayoutResize { left_id: u64, right_id: u64 },
    Module { instance_id: u64 },
}

/// What a handled event commits back to the render loop. `Reorder` carries the new committed layout
/// (the modules Vec is already permuted to match); `Edit` is an add/remove the loop applies via
/// `apply_edit`. Both publish a durable layout change the host should persist.
pub enum Commit {
    Reorder(Vec<Column>),
    Edit(LayoutEdit),
}

/// An open right-click context menu (ADR 0004, Phase F3): its content, the cursor `anchor` it's
/// pinned at (physical px), and the row the cursor is currently over (for the hover highlight).
struct OpenMenu {
    model: MenuModel,
    anchor: (f32, f32),
    hovered: Option<usize>,
}

/// A read-only view of the open menu for the Overlay renderer (`overlay.rs`) — anchor + rows +
/// hovered row. The Overlay re-derives the panel rect from these via `menu::menu_rect`.
pub struct MenuOverlay<'a> {
    pub anchor: (f32, f32),
    pub items: &'a [MenuItem],
    pub hovered: Option<usize>,
}

/// Decide the grab on a press at physical-px `x`. `hit(column_index, local_x)` offers the press to
/// that Module in column-local coords and reports whether it captured: `Captured` → a `Module`
/// grab; an `Ignored` body press → a `LayoutReorder` of the column under the cursor.
pub fn decide_press(
    grab: &mut PointerGrab,
    cols: &[Column],
    viewports: &[Rect],
    x: f32,
    hit: impl FnOnce(usize, f32) -> EventStatus,
) {
    // A press within the gutter of a flex|flex seam grabs the seam for a resize — ahead of the
    // column under it, so the Module never sees a seam press (F4). `resize_boundary_at` only matches
    // flex|flex seams, so a fixed column's edge (e.g. the Loudness meter) is never draggable.
    if let Some(i) = resize_boundary_at(cols, viewports, x, RESIZE_GUTTER_PX) {
        *grab = PointerGrab::LayoutResize {
            left_id: cols[i].instance_id,
            right_id: cols[i + 1].instance_id,
        };
        return;
    }
    let Some(idx) = column_index_at(viewports, x) else {
        return;
    };
    let local_x = x - viewports[idx].x;
    *grab = match hit(idx, local_x) {
        EventStatus::Captured => PointerGrab::Module { instance_id: cols[idx].instance_id },
        EventStatus::Ignored => PointerGrab::LayoutReorder { instance_id: cols[idx].instance_id },
    };
}

/// Smallest physical-px width either flex neighbor of a dragged seam may shrink to — keeps both
/// visible (and their fractions positive) however far the cursor goes.
const MIN_RESIZE_PX: f32 = 24.0;

/// The provisional (and, on release, committed) layout when the seam between `left_id` and `right_id`
/// is dragged to physical-px `cursor_x`. ONLY those two columns retrade: their combined fraction is
/// preserved and re-split by the new pixel ratio, so every other column keeps its width and the
/// window total is unchanged. Sanitized so a degenerate fraction can't reach `set_layout`. Pure —
/// drives both the live preview and the commit.
pub fn resize_preview(
    committed: &[Column],
    viewports: &[Rect],
    left_id: u64,
    right_id: u64,
    cursor_x: f32,
) -> Vec<Column> {
    let mut new = committed.to_vec();
    let (Some(li), Some(ri)) = (
        committed.iter().position(|c| c.instance_id == left_id),
        committed.iter().position(|c| c.instance_id == right_id),
    ) else {
        return new;
    };
    let combined_px = viewports[li].w + viewports[ri].w;
    if combined_px <= 2.0 * MIN_RESIZE_PX {
        return new; // too narrow to split meaningfully — leave the pair as-is
    }
    let left_px = (cursor_x - viewports[li].x).clamp(MIN_RESIZE_PX, combined_px - MIN_RESIZE_PX);
    let ratio = left_px / combined_px;
    let combined_frac = committed[li].width_fraction + committed[ri].width_fraction;
    new[li].width_fraction = combined_frac * ratio;
    new[ri].width_fraction = combined_frac * (1.0 - ratio);
    sanitize_layout(&mut new);
    new
}

/// The provisional (and, on release, committed) order when the column at `dragged` is dragged to
/// physical-px `cursor_x`, hit-tested against the stable `viewports`. Sanitized so a degenerate
/// fraction can never reach `set_layout`. Pure — drives both the live preview and the commit.
pub fn reorder_preview(
    committed: &[Column],
    viewports: &[Rect],
    dragged: usize,
    cursor_x: f32,
) -> Vec<Column> {
    let to = reorder_target(viewports, dragged, cursor_x);
    let mut new = apply_reorder(committed, dragged, to);
    sanitize_layout(&mut new);
    new
}

/// Permute `modules` (1:1 with `old`) into `new`'s order, matched by `instance_id`. Called once on
/// a reorder commit so the modules Vec stays aligned with the committed layout. Total: if `new` isn't
/// a clean permutation of `old` (different length, or an id `old` doesn't have), it leaves `modules`
/// untouched instead of panicking. A reorder always preserves the id set, so this only guards a
/// slipped invariant from crashing the render thread.
fn reorder_modules(
    modules: &mut Vec<Box<dyn Module + Send>>,
    old: &[Column],
    new: &[Column],
) {
    if new.len() != old.len() {
        return;
    }
    // Resolve each new column to its module slot; abort the whole permute if any id is unknown.
    let Some(order) = new
        .iter()
        .map(|c| old.iter().position(|o| o.instance_id == c.instance_id))
        .collect::<Option<Vec<usize>>>()
    else {
        return;
    };
    let mut slots: Vec<Option<Box<dyn Module + Send>>> = modules.drain(..).map(Some).collect();
    *modules = order.into_iter().filter_map(|oi| slots[oi].take()).collect();
}

/// The render-side router. Owns transient drag state; the loop calls [`Router::handle`] per
/// buffered event, then reads [`Router::provisional`] for this frame's render order.
pub struct Router {
    grab: PointerGrab,
    /// Latest cursor in PHYSICAL window px. `ButtonPressed`/`Released` carry no position in
    /// baseview, so the press decision reads the last `CursorMoved` from here.
    last_cursor: Option<(f32, f32)>,
    /// The live-reflow order while a `LayoutReorder` is dragging; `None` otherwise.
    provisional: Option<Vec<Column>>,
    /// The open right-click context menu, if any. While `Some` it's MODAL — pointer input drives the
    /// menu (hover/select/dismiss) and reaches no Module and starts no grab (Phase F3).
    menu: Option<OpenMenu>,
}

impl Router {
    pub fn new() -> Self {
        Self { grab: PointerGrab::None, last_cursor: None, provisional: None, menu: None }
    }

    /// The live-reflow order to render this frame, or `None` to render the committed layout.
    pub fn provisional(&self) -> Option<&[Column]> {
        self.provisional.as_deref()
    }

    /// Dismiss any open context menu. Called when the surface resizes: the anchor is captured in
    /// physical px at open time, so a resize (especially a DPI/scale change) would otherwise leave the
    /// panel pinned to stale coordinates — closing it is the clean, expected behavior. Idempotent.
    pub fn close_menu(&mut self) {
        self.menu = None;
    }

    /// A read-only view of the open menu for the Overlay renderer, or `None` when no menu is open.
    pub fn menu_overlay(&self) -> Option<MenuOverlay<'_>> {
        self.menu.as_ref().map(|m| MenuOverlay {
            anchor: m.anchor,
            items: &m.model.items,
            hovered: m.hovered,
        })
    }

    /// Open the context menu at the last cursor, with content for whatever column is under it
    /// (`None` → empty strip / past every column: Add appends, no Remove).
    fn open_menu(&mut self, committed_vps: &[Rect]) {
        let Some(anchor) = self.last_cursor else {
            return;
        };
        let column = column_index_at(committed_vps, anchor.0);
        self.menu = Some(OpenMenu { model: MenuModel::for_context(column), anchor, hovered: None });
    }

    /// Drive the open menu (modal). Cursor-moves update the hovered row; a left-press selects (→
    /// `Commit::Edit`) or dismisses; a right-press reopens at the new cursor; everything else (mouse
    /// releases, wheel, cursor-left) is swallowed so it can't reach a Module or start a grab.
    fn handle_menu(
        &mut self,
        event: &baseview::Event,
        committed_vps: &[Rect],
        surface_w: f32,
        surface_h: f32,
        scale: f32,
    ) -> Option<Commit> {
        use baseview::{Event, MouseButton, MouseEvent};
        match event {
            Event::Mouse(MouseEvent::CursorMoved { position, .. }) => {
                let cursor = (position.x as f32 * scale, position.y as f32 * scale);
                self.last_cursor = Some(cursor);
                if let Some(menu) = &mut self.menu {
                    let rect = menu_rect(menu.anchor, menu.model.len(), surface_w, surface_h, scale);
                    menu.hovered = menu_item_at(rect, menu.model.len(), cursor);
                }
                None
            }
            Event::Mouse(MouseEvent::ButtonPressed { button: MouseButton::Left, .. }) => {
                let cursor = self.last_cursor?;
                let menu = self.menu.take()?; // any left-press closes the menu (select or dismiss)
                menu.model
                    .edit_at_cursor(menu.anchor, surface_w, surface_h, scale, cursor)
                    .map(Commit::Edit)
            }
            Event::Mouse(MouseEvent::ButtonPressed { button: MouseButton::Right, .. }) => {
                self.menu = None;
                self.open_menu(committed_vps);
                None
            }
            _ => None,
        }
    }

    /// Translate a baseview event into a column-local PHYSICAL-px event for a Module: logical →
    /// physical (`× scale`), then subtract the column origin. Only `CursorMoved` carries a position;
    /// everything else is forwarded verbatim (the Module reads the last local `CursorMoved` instead).
    fn to_local(&self, event: &baseview::Event, vp: Rect, scale: f32) -> baseview::Event {
        use baseview::{Event, MouseEvent, Point};
        if let Event::Mouse(MouseEvent::CursorMoved { position, modifiers }) = event {
            Event::Mouse(MouseEvent::CursorMoved {
                position: Point::new(
                    position.x * scale as f64 - vp.x as f64,
                    position.y * scale as f64 - vp.y as f64,
                ),
                modifiers: *modifiers,
            })
        } else {
            event.clone()
        }
    }

    /// Forward `event` to the column at `idx` in column-local coords; returns what it reported.
    fn forward(
        &self,
        idx: usize,
        viewports: &[Rect],
        modules: &mut [Box<dyn Module + Send>],
        event: &baseview::Event,
        scale: f32,
    ) -> EventStatus {
        let vp = viewports[idx];
        let local = self.to_local(event, vp, scale);
        modules[idx].on_event(&local, vp)
    }

    /// Handle one event against the stable `committed` layout (1:1 with `modules`) + its
    /// `committed_vps`. Returns `Some(Commit)` when something durable happens — a reorder commit on
    /// release (modules already permuted to match) or a menu add/remove selection; `None` otherwise.
    /// `surface_w`/`surface_h` (physical px) size the context-menu geometry.
    #[allow(clippy::too_many_arguments)]
    pub fn handle(
        &mut self,
        event: &baseview::Event,
        committed: &[Column],
        committed_vps: &[Rect],
        modules: &mut Vec<Box<dyn Module + Send>>,
        surface_w: f32,
        surface_h: f32,
        scale: f32,
    ) -> Option<Commit> {
        use baseview::{Event, MouseButton, MouseEvent};
        // A right-click context menu is modal while open: it owns all pointer input.
        if self.menu.is_some() {
            return self.handle_menu(event, committed_vps, surface_w, surface_h, scale);
        }
        match event {
            // Right-press opens the menu at the cursor — but never mid-drag (a left grab owns the
            // pointer until its release).
            Event::Mouse(MouseEvent::ButtonPressed { button: MouseButton::Right, .. }) => {
                if self.grab == PointerGrab::None {
                    self.open_menu(committed_vps);
                }
                None
            }
            Event::Mouse(MouseEvent::CursorMoved { position, .. }) => {
                let x = position.x as f32 * scale;
                self.last_cursor = Some((x, position.y as f32 * scale));
                match self.grab {
                    PointerGrab::LayoutReorder { instance_id } => {
                        let di = committed.iter().position(|c| c.instance_id == instance_id)?;
                        self.provisional = Some(reorder_preview(committed, committed_vps, di, x));
                    }
                    PointerGrab::LayoutResize { left_id, right_id } => {
                        // Live-reflow the seam: re-split the two neighbors at the cursor, hit-tested
                        // against the STABLE committed viewports (the seam stays under the cursor).
                        self.provisional =
                            Some(resize_preview(committed, committed_vps, left_id, right_id, x));
                    }
                    PointerGrab::Module { instance_id } => {
                        if let Some(idx) =
                            committed.iter().position(|c| c.instance_id == instance_id)
                        {
                            self.forward(idx, committed_vps, modules, event, scale);
                        }
                    }
                    // Ungrabbed hover: forward to the column under the cursor (the hover path — a
                    // Waveform records the dB under the cursor; a Module mutates state, returns Ignored).
                    PointerGrab::None => {
                        if let Some(idx) = column_index_at(committed_vps, x) {
                            self.forward(idx, committed_vps, modules, event, scale);
                        }
                    }
                }
                None
            }

            Event::Mouse(MouseEvent::ButtonPressed { button: MouseButton::Left, .. }) => {
                let (x, _) = self.last_cursor?;
                let mut grab = PointerGrab::None;
                decide_press(&mut grab, committed, committed_vps, x, |idx, _local_x| {
                    self.forward(idx, committed_vps, modules, event, scale)
                });
                self.grab = grab;
                None
            }

            Event::Mouse(MouseEvent::ButtonReleased { button: MouseButton::Left, .. }) => {
                let committed_new = match self.grab {
                    // Both layout drags commit the provisional layout on release. For a resize the
                    // column order is unchanged, so the `reorder_modules` below is an identity permute.
                    PointerGrab::LayoutReorder { .. } | PointerGrab::LayoutResize { .. } => {
                        self.provisional.take()
                    }
                    PointerGrab::Module { instance_id } => {
                        if let Some(idx) =
                            committed.iter().position(|c| c.instance_id == instance_id)
                        {
                            self.forward(idx, committed_vps, modules, event, scale);
                        }
                        None
                    }
                    PointerGrab::None => None,
                };
                self.grab = PointerGrab::None;
                self.provisional = None;
                if let Some(new) = committed_new {
                    reorder_modules(modules, committed, &new);
                    return Some(Commit::Reorder(new));
                }
                None
            }

            Event::Mouse(MouseEvent::WheelScrolled { .. }) => {
                // Scroll carries no position (baseview), so route it to the column under the last
                // cursor — only when ungrabbed; scrolling mid-drag isn't a gesture we define. The
                // event forwards as-is (to_local only translates CursorMoved; the module reads delta).
                if let (PointerGrab::None, Some((x, _))) = (self.grab, self.last_cursor) {
                    if let Some(idx) = column_index_at(committed_vps, x) {
                        self.forward(idx, committed_vps, modules, event, scale);
                    }
                }
                None
            }

            // CursorLeft fires mid-drag (macOS tracking-area quirk) — it must NOT end a grab; a grab
            // ends only on ButtonReleased. We just drop it.
            _ => None,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::layout::{module_type, viewports, Column};
    use crate::module::FrameContext;

    fn two_flex() -> Vec<Column> {
        vec![
            Column::new(0, module_type::WAVEFORM, 0.5),
            Column::new(1, module_type::WAVEFORM, 0.5),
        ]
    }

    /// A no-GPU Module whose `save_config` byte tags which one it is, so a permute is observable.
    /// `render`/`update` are unreachable no-ops in these pure-logic tests.
    struct FakeMod {
        tag: u8,
    }
    impl Module for FakeMod {
        fn update(&mut self, _c: &FrameContext, _q: &wgpu::Queue) {}
        fn render(&mut self, _r: &mut wgpu::RenderPass, _v: Rect) {}
        fn on_event(&mut self, _e: &baseview::Event, _v: Rect) -> EventStatus {
            EventStatus::Ignored
        }
        fn save_config(&self) -> Vec<u8> {
            vec![self.tag]
        }
        fn load_config(&mut self, _b: &[u8]) {}
    }

    fn fakes(tags: &[u8]) -> Vec<Box<dyn Module + Send>> {
        tags.iter().map(|&t| Box::new(FakeMod { tag: t }) as Box<dyn Module + Send>).collect()
    }

    fn tags(modules: &[Box<dyn Module + Send>]) -> Vec<u8> {
        modules.iter().map(|m| m.save_config()[0]).collect()
    }

    #[test]
    fn reorder_modules_permutes_by_id() {
        let old = vec![
            Column::new(0, module_type::WAVEFORM, 1.0),
            Column::new(1, module_type::WAVEFORM, 1.0),
            Column::new(2, module_type::WAVEFORM, 1.0),
        ];
        // new order: ids [2, 0, 1] → modules follow their columns, not their slots.
        let new = vec![old[2].clone(), old[0].clone(), old[1].clone()];
        let mut modules = fakes(&[0, 1, 2]);
        reorder_modules(&mut modules, &old, &new);
        assert_eq!(tags(&modules), vec![2, 0, 1]);
    }

    #[test]
    fn reorder_modules_bails_on_id_mismatch() {
        // `new` names an id (9) that isn't in `old`: not a clean permutation, so leave modules as-is
        // rather than panic (the old code `.unwrap()`d here).
        let old = two_flex(); // ids 0, 1
        let new = vec![old[0].clone(), Column::new(9, module_type::WAVEFORM, 0.5)];
        let mut modules = fakes(&[0, 1]);
        reorder_modules(&mut modules, &old, &new);
        assert_eq!(tags(&modules), vec![0, 1], "untouched when the permutation is invalid");
    }

    #[test]
    fn body_press_on_an_ignoring_module_begins_a_reorder() {
        let cols = two_flex();
        let vp = viewports(&cols, 800.0, 600.0, 1.0);
        let mut grab = PointerGrab::None;
        // Module ignores → body press → reorder grab of the column under x=100 (col 0).
        decide_press(&mut grab, &cols, &vp, 100.0, |_idx, _local_x| EventStatus::Ignored);
        assert_eq!(grab, PointerGrab::LayoutReorder { instance_id: 0 });
    }

    #[test]
    fn press_on_a_capturing_module_begins_a_module_grab() {
        let cols = two_flex();
        let vp = viewports(&cols, 800.0, 600.0, 1.0);
        let mut grab = PointerGrab::None;
        decide_press(&mut grab, &cols, &vp, 500.0, |_idx, _local_x| EventStatus::Captured);
        assert_eq!(grab, PointerGrab::Module { instance_id: 1 });
    }

    #[test]
    fn press_outside_every_column_leaves_no_grab() {
        let cols = two_flex();
        let vp = viewports(&cols, 800.0, 600.0, 1.0);
        let mut grab = PointerGrab::None;
        decide_press(&mut grab, &cols, &vp, 9000.0, |_, _| EventStatus::Ignored);
        assert_eq!(grab, PointerGrab::None);
    }

    #[test]
    fn reorder_preview_permutes_the_order_by_cursor_x() {
        let cols = two_flex();
        let vp = viewports(&cols, 800.0, 600.0, 1.0);
        // Dragging col 0, cursor past col 1's midpoint (>600) → [1, 0].
        let new = reorder_preview(&cols, &vp, 0, 700.0);
        assert_eq!(new.iter().map(|c| c.instance_id).collect::<Vec<_>>(), vec![1, 0]);
        // Cursor still in col 0's half → order unchanged.
        let same = reorder_preview(&cols, &vp, 0, 100.0);
        assert_eq!(same.iter().map(|c| c.instance_id).collect::<Vec<_>>(), vec![0, 1]);
    }

    // ── F4: dragging the seam between two flex columns to retrade their widths (ADR 0004) ──

    #[test]
    fn seam_press_between_two_flex_columns_begins_a_resize() {
        let cols = two_flex();
        let vp = viewports(&cols, 800.0, 600.0, 1.0); // seam at 400
        let mut grab = PointerGrab::None;
        // A press within the gutter of the flex|flex seam grabs the seam, NOT the column body — so
        // the `hit` closure (which would capture/reorder) is never even consulted.
        decide_press(&mut grab, &cols, &vp, 402.0, |_, _| panic!("module must not be offered a seam press"));
        assert_eq!(grab, PointerGrab::LayoutResize { left_id: 0, right_id: 1 });
    }

    #[test]
    fn resize_preview_redistributes_between_the_two_neighbors() {
        let cols = two_flex(); // 0.5 / 0.5, seam at 400
        let vp = viewports(&cols, 800.0, 600.0, 1.0);
        // Drag the seam left to x=300: col0 shrinks, col1 grows, combined fraction preserved.
        let new = resize_preview(&cols, &vp, 0, 1, 300.0);
        assert!((new[0].width_fraction - 0.375).abs() < 1e-3, "left → 300/800");
        assert!((new[1].width_fraction - 0.625).abs() < 1e-3, "right → 500/800");
        assert!((new[0].width_fraction + new[1].width_fraction - 1.0).abs() < 1e-6, "combined preserved");
    }

    #[test]
    fn resize_preview_leaves_other_columns_untouched() {
        let cols = vec![
            Column::new(0, module_type::WAVEFORM, 0.25),
            Column::new(1, module_type::WAVEFORM, 0.25),
            Column::new(2, module_type::WAVEFORM, 0.5),
        ];
        let vp = viewports(&cols, 800.0, 600.0, 1.0); // [0..200],[200..400],[400..800]; 0|1 seam at 200
        let new = resize_preview(&cols, &vp, 0, 1, 100.0);
        assert!((new[2].width_fraction - 0.5).abs() < 1e-6, "the third column is untouched");
        assert!(
            (new[0].width_fraction + new[1].width_fraction - 0.5).abs() < 1e-6,
            "the pair's combined fraction is preserved"
        );
        assert!(new[0].width_fraction < new[1].width_fraction, "left shrank");
    }

    #[test]
    fn resize_preview_clamps_so_neither_neighbor_vanishes() {
        let cols = two_flex();
        let vp = viewports(&cols, 800.0, 600.0, 1.0);
        // Drag far past the left edge — the left column clamps to a minimum, never 0 or negative.
        let new = resize_preview(&cols, &vp, 0, 1, -500.0);
        assert!(new[0].width_fraction.is_finite() && new[0].width_fraction > 0.0);
        assert!(new[1].width_fraction.is_finite() && new[1].width_fraction > 0.0);
        assert!(new[0].width_fraction < new[1].width_fraction, "dragged left → left is the smaller");
    }
}
