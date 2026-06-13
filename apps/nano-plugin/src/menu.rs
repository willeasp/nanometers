//! The host right-click context menu — pure model + geometry (ADR 0004 amendment, Phase F3).
//!
//! A right-click opens a flat menu anchored at the cursor: `Add Waveform / Add Oscilloscope /
//! Add Loudness`, plus `Remove` when the click was over a column. Selecting a row yields a
//! [`LayoutEdit`] the render loop applies. Everything here is pure (no GPU, no threads): the Router
//! (`input.rs`) owns the open/hover state machine and the Overlay (`overlay.rs`) draws it, both
//! driving these functions. Geometry is in PHYSICAL px to match the render-side router (ADR 0004).

use crate::editor::LayoutEdit;
use crate::layout::module_type;
use crate::module::Rect;

/// A row's width, in LOGICAL px (× display scale at geometry time). Wide enough for "Add Oscilloscope".
const ITEM_W: f32 = 168.0;
/// A row's height, in LOGICAL px.
const ITEM_H: f32 = 24.0;

/// What choosing a row does. `Add` carries the Module type tag to spawn.
#[derive(Clone, Copy, Debug, PartialEq)]
enum MenuAction {
    Add(&'static str),
    Remove,
}

/// One row of the context menu. `label` is what the Overlay draws.
pub struct MenuItem {
    pub label: String,
    action: MenuAction,
}

/// The menu's content, derived from where the right-click landed. `column` is the column under the
/// cursor (`None` on an empty strip or past every column) — it decides both whether `Remove` appears
/// and where an `Add` inserts.
///
/// `column` is a positional INDEX, not an instance_id, so it's only valid while the layout is
/// unchanged. That holds because the menu is modal (`input.rs`): no reorder/add/remove can land
/// between opening the menu and applying its selection — the selection is committed synchronously in
/// the same input batch. If that modal guarantee is ever relaxed, switch this to an instance_id.
pub struct MenuModel {
    pub items: Vec<MenuItem>,
    column: Option<usize>,
}

impl MenuModel {
    /// Build the menu for a right-click over `column` (`None` → no column / empty strip: Add appends,
    /// no Remove). The three Add rows are always present; multiple instances of a type are allowed,
    /// so no type is ever disabled.
    pub fn for_context(column: Option<usize>) -> Self {
        let mut items = vec![
            MenuItem { label: "Add Waveform".into(), action: MenuAction::Add(module_type::WAVEFORM) },
            MenuItem {
                label: "Add Oscilloscope".into(),
                action: MenuAction::Add(module_type::OSCILLOSCOPE),
            },
            MenuItem { label: "Add Loudness".into(), action: MenuAction::Add(module_type::LOUDNESS) },
        ];
        if column.is_some() {
            items.push(MenuItem { label: "Remove".into(), action: MenuAction::Remove });
        }
        Self { items, column }
    }

    pub fn len(&self) -> usize {
        self.items.len()
    }

    /// The [`LayoutEdit`] for choosing row `item`, or `None` if `item` is out of range (or `Remove`
    /// with no column, which `for_context` never emits). `Add` over a column inserts right after it;
    /// with no column it appends via the `usize::MAX` sentinel `insert_column` clamps to the end.
    pub fn to_edit(&self, item: usize) -> Option<LayoutEdit> {
        match self.items.get(item)?.action {
            MenuAction::Add(ty) => Some(LayoutEdit::Insert {
                after: self.column.unwrap_or(usize::MAX),
                module_type: ty.to_string(),
            }),
            MenuAction::Remove => Some(LayoutEdit::Remove { index: self.column? }),
        }
    }

    /// Resolve a click at physical-px `cursor` against this menu anchored at `anchor`: the
    /// [`LayoutEdit`] if it landed on a row, else `None` (a click outside the panel — dismiss). The
    /// Router calls this on a left-press, then closes the menu regardless of the outcome.
    pub fn edit_at_cursor(
        &self,
        anchor: (f32, f32),
        surface_w: f32,
        surface_h: f32,
        scale: f32,
        cursor: (f32, f32),
    ) -> Option<LayoutEdit> {
        let rect = menu_rect(anchor, self.len(), surface_w, surface_h, scale);
        menu_item_at(rect, self.len(), cursor).and_then(|row| self.to_edit(row))
    }
}

/// The menu panel rectangle in PHYSICAL px for `n_items` rows anchored at `anchor` (the cursor),
/// shifted so it never spills off the surface (clamped to `[0, surface - size]`). `scale` converts
/// the logical per-row size to physical px.
pub fn menu_rect(anchor: (f32, f32), n_items: usize, surface_w: f32, surface_h: f32, scale: f32) -> Rect {
    let w = ITEM_W * scale;
    let h = ITEM_H * scale * n_items as f32;
    let x = anchor.0.min((surface_w - w).max(0.0)).max(0.0);
    let y = anchor.1.min((surface_h - h).max(0.0)).max(0.0);
    Rect { x, y, w, h }
}

/// Which row (0-based) physical-px `cursor` is over within an already-laid-out `rect` of `n_items`
/// rows, or `None` if the cursor is outside the panel. Rows are equal-height top-to-bottom.
pub fn menu_item_at(rect: Rect, n_items: usize, cursor: (f32, f32)) -> Option<usize> {
    if n_items == 0
        || cursor.0 < rect.x
        || cursor.0 >= rect.x + rect.w
        || cursor.1 < rect.y
        || cursor.1 >= rect.y + rect.h
    {
        return None;
    }
    let row = ((cursor.1 - rect.y) / (rect.h / n_items as f32)) as usize;
    Some(row.min(n_items - 1))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn items_over_a_column_include_remove() {
        let over = MenuModel::for_context(Some(2));
        assert_eq!(over.len(), 4, "3 Add rows + Remove");
        assert_eq!(over.items[3].label, "Remove");

        let empty = MenuModel::for_context(None);
        assert_eq!(empty.len(), 3, "no column → no Remove");
        assert!(empty.items.iter().all(|i| i.label.starts_with("Add")));
    }

    #[test]
    fn edit_for_selection_maps_rows_to_layout_edits() {
        let over = MenuModel::for_context(Some(2));
        // Row 2 = "Add Loudness" → insert right after column 2.
        assert_eq!(
            over.to_edit(2),
            Some(LayoutEdit::Insert { after: 2, module_type: module_type::LOUDNESS.into() })
        );
        // Row 3 = "Remove" → remove column 2.
        assert_eq!(over.to_edit(3), Some(LayoutEdit::Remove { index: 2 }));
        assert_eq!(over.to_edit(9), None, "out of range");

        // Empty strip: Add appends via the usize::MAX sentinel insert_column clamps.
        let empty = MenuModel::for_context(None);
        assert_eq!(
            empty.to_edit(0),
            Some(LayoutEdit::Insert { after: usize::MAX, module_type: module_type::WAVEFORM.into() })
        );
    }

    #[test]
    fn menu_rect_clamps_to_surface() {
        // Anchor hard against the bottom-right corner: the panel shifts fully on-surface.
        let r = menu_rect((795.0, 595.0), 4, 800.0, 600.0, 1.0);
        assert!(r.x + r.w <= 800.0, "right edge stays on-surface");
        assert!(r.y + r.h <= 600.0, "bottom edge stays on-surface");
        assert!(r.x >= 0.0 && r.y >= 0.0);

        // A comfortable anchor keeps the panel at the cursor.
        let r2 = menu_rect((100.0, 100.0), 4, 800.0, 600.0, 1.0);
        assert_eq!((r2.x, r2.y), (100.0, 100.0));
        assert_eq!(r2.w, ITEM_W);
        assert_eq!(r2.h, ITEM_H * 4.0);
    }

    #[test]
    fn edit_at_cursor_selects_a_row_or_dismisses() {
        let model = MenuModel::for_context(Some(0)); // 4 rows, anchored at (100, 100), scale 1
        let anchor = (100.0, 100.0);
        // Click on row 0 ("Add Waveform") → insert after column 0.
        assert_eq!(
            model.edit_at_cursor(anchor, 800.0, 600.0, 1.0, (120.0, 108.0)),
            Some(LayoutEdit::Insert { after: 0, module_type: module_type::WAVEFORM.into() })
        );
        // Click on row 3 ("Remove") → remove column 0.
        assert_eq!(
            model.edit_at_cursor(anchor, 800.0, 600.0, 1.0, (120.0, 180.0)),
            Some(LayoutEdit::Remove { index: 0 })
        );
        // Click outside the panel → dismiss (no edit).
        assert_eq!(model.edit_at_cursor(anchor, 800.0, 600.0, 1.0, (500.0, 500.0)), None);
    }

    #[test]
    fn menu_item_at_maps_cursor_y_to_row() {
        let rect = menu_rect((100.0, 100.0), 4, 800.0, 600.0, 1.0); // rows at y 100,124,148,172
        assert_eq!(menu_item_at(rect, 4, (110.0, 100.0)), Some(0), "top row");
        assert_eq!(menu_item_at(rect, 4, (110.0, 130.0)), Some(1), "second row");
        assert_eq!(menu_item_at(rect, 4, (110.0, 195.0)), Some(3), "last row");
        assert_eq!(menu_item_at(rect, 4, (300.0, 130.0)), None, "right of the panel");
        assert_eq!(menu_item_at(rect, 4, (110.0, 50.0)), None, "above the panel");
        assert_eq!(menu_item_at(rect, 4, (110.0, 300.0)), None, "below the panel");
    }
}
