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

use crate::layout::{apply_reorder, column_index_at, reorder_target, sanitize_layout, Column};
use crate::module::{EventStatus, Module, Rect};

/// Which owner holds the pointer until mouse-up (ADR 0004). `LayoutResize` is deferred to Phase F
/// (no draggable flex|flex boundary exists until multi-instance), so its arm isn't built here.
#[derive(Debug, Clone, Copy, PartialEq)]
pub enum PointerGrab {
    None,
    LayoutReorder { instance_id: u64 },
    Module { instance_id: u64 },
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
    let Some(idx) = column_index_at(viewports, x) else {
        return;
    };
    let local_x = x - viewports[idx].x;
    *grab = match hit(idx, local_x) {
        EventStatus::Captured => PointerGrab::Module { instance_id: cols[idx].instance_id },
        EventStatus::Ignored => PointerGrab::LayoutReorder { instance_id: cols[idx].instance_id },
    };
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
}

impl Router {
    pub fn new() -> Self {
        Self { grab: PointerGrab::None, last_cursor: None, provisional: None }
    }

    /// The live-reflow order to render this frame, or `None` to render the committed layout.
    pub fn provisional(&self) -> Option<&[Column]> {
        self.provisional.as_deref()
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
    /// `committed_vps`. Returns `Some(new_layout)` when a reorder COMMITS on release — the caller
    /// adopts it (modules are already permuted to match); `None` otherwise.
    pub fn handle(
        &mut self,
        event: &baseview::Event,
        committed: &[Column],
        committed_vps: &[Rect],
        modules: &mut Vec<Box<dyn Module + Send>>,
        scale: f32,
    ) -> Option<Vec<Column>> {
        use baseview::{Event, MouseButton, MouseEvent};
        match event {
            Event::Mouse(MouseEvent::CursorMoved { position, .. }) => {
                let x = position.x as f32 * scale;
                self.last_cursor = Some((x, position.y as f32 * scale));
                match self.grab {
                    PointerGrab::LayoutReorder { instance_id } => {
                        let di = committed.iter().position(|c| c.instance_id == instance_id)?;
                        self.provisional = Some(reorder_preview(committed, committed_vps, di, x));
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
                    PointerGrab::LayoutReorder { .. } => self.provisional.take(),
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
                    return Some(new);
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
}
