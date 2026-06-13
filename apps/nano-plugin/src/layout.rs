//! Layout — the flat horizontal strip of resizable, reorderable Module columns (ADR 0003).
//!
//! The host owns the list and the geometry; each Module owns its opaque `config` blob. List order is
//! left→right placement. A column either OWNS a fixed logical-pixel width (`fixed_width_px`) or
//! FLEXES — taking a share of the leftover width by `width_fraction`. Fixed columns keep their size
//! across a window resize (a meter shouldn't reflow); the flexing columns (e.g. the Waveform) absorb
//! the rest. Logical sizes are scaled to the surface's physical px at tiling time.

use serde::{Deserialize, Serialize};

use crate::module::Rect;

/// Canonical Module type tags. `Column.module_type` is a `String` (not an enum) so a type written
/// by a future build that this one doesn't know deserializes losslessly instead of failing the
/// whole `editor-state` load — and is preserved on re-save. Build-time resolution maps a known tag
/// to a Module constructor; an unknown tag → a placeholder that renders nothing and keeps its bytes.
pub mod module_type {
    pub const OSCILLOSCOPE: &str = "oscilloscope";
    pub const WAVEFORM: &str = "waveform";
    pub const LOUDNESS: &str = "loudness";
}

// The Loudness column's fixed width isn't a magic number here — it comes from
// `loudness::intrinsic_width()`, derived from that module's own layout knobs. Persisted layouts can
// carry a stale (or missing) width, so the host re-pins every intrinsically-sized column from its
// LIVE module at editor spawn via [`reconcile_fixed_widths`] — the module stays the one source of
// truth and the persisted value is only a cache.

/// One column in the strip: an instance of a Module type, plus the Module's own opaque config blob
/// (ADR 0003 — the host stores it, never reads it). Width is EITHER `fixed_width_px` (logical px the
/// column owns) OR, when that's `None`, a `width_fraction` share of the space the fixed columns leave.
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
pub struct Column {
    pub instance_id: u64,
    pub module_type: String,
    pub width_fraction: f32,
    /// `Some(px)` → the column owns this logical width and ignores `width_fraction`; `None` → flexes.
    #[serde(default)]
    pub fixed_width_px: Option<f32>,
    #[serde(default)]
    pub config: Vec<u8>,
}

impl Column {
    /// A flexing column that takes `width_fraction` of the space left by the fixed columns.
    pub fn new(instance_id: u64, module_type: &str, width_fraction: f32) -> Self {
        Self {
            instance_id,
            module_type: module_type.to_string(),
            width_fraction,
            fixed_width_px: None,
            config: Vec::new(),
        }
    }

    /// A column that owns a fixed logical-pixel width; the rest of the strip flexes around it.
    pub fn fixed(instance_id: u64, module_type: &str, width_px: f32) -> Self {
        Self {
            instance_id,
            module_type: module_type.to_string(),
            width_fraction: 0.0,
            fixed_width_px: Some(width_px),
            config: Vec::new(),
        }
    }
}

/// The next free instance id for a runtime-added column: one past the current max (0 when empty).
/// Ids need only be unique among present columns (the router and reorder match by id), so reusing a
/// freed id is harmless — they aren't durable handles, and this needs no persisted counter.
pub fn next_instance_id(cols: &[Column]) -> u64 {
    cols.iter().map(|c| c.instance_id).max().map_or(0, |m| m.saturating_add(1))
}

/// Insert a fresh FLEX column of `module_type` right after index `after` (clamped to the end), with a
/// newly-allocated id. Returns the insertion index so the caller can drop the matching Module into
/// the same slot. Intrinsic (fixed) sizing is reconciled by the caller from the built module — the
/// same split as spawn, since layout has no view of Module widths.
pub fn insert_column(cols: &mut Vec<Column>, after: usize, module_type: &str) -> usize {
    let id = next_instance_id(cols);
    // saturating_add so `usize::MAX` is a safe "append at the end" sentinel (the empty-strip / no-column
    // menu case) — it clamps to len rather than overflowing.
    let at = after.saturating_add(1).min(cols.len());
    cols.insert(at, Column::new(id, module_type, 1.0));
    at
}

/// Remove the column at `index`, returning its instance_id; `None` if out of range. No minimum count —
/// an empty strip is a valid state (it shows the right-click hint), so the caller drops the matching
/// Module at the same index without a floor check.
pub fn remove_column(cols: &mut Vec<Column>, index: usize) -> Option<u64> {
    (index < cols.len()).then(|| cols.remove(index).instance_id)
}

/// The app-default layout for a fresh instance with no persisted state (ADR 0003): the Waveform
/// flexes to fill the window, with the Loudness meter pinned to a fixed width on the right.
pub fn default_layout() -> Vec<Column> {
    vec![
        Column::new(0, module_type::WAVEFORM, 1.0),
        Column::fixed(1, module_type::LOUDNESS, crate::module::loudness::intrinsic_width()),
    ]
}

/// Re-pin every column whose live Module reports an intrinsic width (`intrinsic_widths` is 1:1 with
/// `cols`, from `Module::intrinsic_width()`). Called at editor spawn, AFTER the modules are built:
/// the module — not the persisted bytes — is the source of truth for an intrinsically-sized column,
/// so a layout-knob edit reflows old sessions and legacy flex columns migrate to fixed automatically.
/// Columns whose module reports `None` keep their persisted shape.
pub fn reconcile_fixed_widths(cols: &mut [Column], intrinsic_widths: &[Option<f32>]) {
    for (col, w) in cols.iter_mut().zip(intrinsic_widths) {
        if w.is_some() {
            col.fixed_width_px = *w;
        }
    }
}

/// Integer-pixel column rectangles tiling the surface left→right with NO gaps or overlaps (ADR 0003).
/// Fixed columns take `fixed_width_px × scale` (logical → physical); the flexing columns split the
/// remainder by `width_fraction`. One remainder rule covers every shape: the last flexing column —
/// or the last column outright when all are fixed — absorbs whatever rounding leaves over, so the
/// widths sum to exactly the surface. Tiling clamps each rect to the surface: when fixed widths
/// over-claim a too-narrow window the rightmost columns clip instead of extending past the edge
/// (an out-of-attachment `set_viewport`/`set_scissor_rect` is a wgpu validation error).
/// Each `Rect` is integer px so it converts cleanly to wgpu's u32 `set_scissor_rect`.
pub fn viewports(cols: &[Column], surface_w: f32, surface_h: f32, scale: f32) -> Vec<Rect> {
    let n = cols.len();
    if n == 0 {
        return Vec::new();
    }
    let total = surface_w.max(0.0).round() as i64;

    // 1) Fixed columns claim their (scaled, rounded) logical width up front.
    let mut widths = vec![0i64; n];
    let mut fixed_sum = 0i64;
    for (i, c) in cols.iter().enumerate() {
        if let Some(px) = c.fixed_width_px {
            let pw = (px * scale).round().max(0.0) as i64;
            widths[i] = pw;
            fixed_sum += pw;
        }
    }

    // 2) The flexing columns split whatever's left, by fraction (floored)…
    let flex_px = (total - fixed_sum).max(0);
    let flex: Vec<usize> = (0..n).filter(|&i| cols[i].fixed_width_px.is_none()).collect();
    let frac_total: f32 = flex.iter().map(|&i| cols[i].width_fraction).sum();
    let frac_total = if frac_total > 0.0 { frac_total } else { 1.0 };
    for &i in &flex {
        widths[i] = (flex_px as f32 * (cols[i].width_fraction / frac_total)).floor() as i64;
    }
    // …then ONE absorber takes the remainder (rounding, or the deficit when fixed over-claims —
    // possibly negative, clamped at tiling): the last flexing column, or the last column outright.
    let absorb = flex.last().copied().unwrap_or(n - 1);
    let sum: i64 = widths.iter().sum();
    widths[absorb] += total - sum;

    // 3) Tile left→right, each width clamped to the surface that remains.
    let mut rects = Vec::with_capacity(n);
    let mut x = 0i64;
    for &wv in &widths {
        let wv = wv.clamp(0, (total - x).max(0));
        rects.push(Rect { x: x as f32, y: 0.0, w: wv as f32, h: surface_h });
        x += wv;
    }
    rects
}

// ──────────────────────────────────────────────────────────────────────────────────────────
// Hit-testing / reorder helpers for the pointer-grab router (Phase E, ADR 0004). All PURE: they
// take the laid-out `viewports` (physical px) + a physical-px cursor `x` and never touch the GPU
// or threads — the render-side `Router` drives them.
// ──────────────────────────────────────────────────────────────────────────────────────────

/// Smallest flex fraction [`sanitize_layout`] will pin a degenerate value to — keeps a column
/// visible and, crucially, finite-positive so it can't serialize to a load-breaking JSON `null`.
const MIN_FLEX_FRACTION: f32 = 0.05;

/// Map each column in `layout` order to its viewport, looked up from the `active` order's
/// `active_vps` by instance_id. `active` is the provisional reorder order while a column drags (the
/// strip re-tiles to preview the drop), else `layout` itself (identity). The modules Vec stays in
/// committed `layout` order, so this returns each module's rect in that order. The live code keeps all
/// three slices the same length (provisional is a permutation of the committed layout), so the
/// `unwrap_or(i)` identity fallback resolves; the final `.get(j)` is a belt-and-suspenders guard so a
/// future slip degrades to an empty (draw-nothing) rect instead of panicking the render thread — the
/// whole point of extracting this off the old inline `.expect`.
pub fn remap_to_layout_order(layout: &[Column], active: &[Column], active_vps: &[Rect]) -> Vec<Rect> {
    let empty = Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 };
    layout
        .iter()
        .enumerate()
        .map(|(i, c)| {
            let j = active.iter().position(|a| a.instance_id == c.instance_id).unwrap_or(i);
            active_vps.get(j).copied().unwrap_or(empty)
        })
        .collect()
}

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

/// The physical-px x of every DRAGGABLE seam — the boundary between two adjacent FLEX columns (the
/// only resizable seams, [`resize_boundary_at`]). The Overlay draws a hairline at each so the resize
/// affordance is visible; a fixed column's edge (e.g. the Loudness meter) is excluded.
pub fn draggable_seams(cols: &[Column], viewports: &[Rect]) -> Vec<f32> {
    (0..cols.len().saturating_sub(1))
        .filter(|&i| cols[i].fixed_width_px.is_none() && cols[i + 1].fixed_width_px.is_none())
        .map(|i| viewports[i].x + viewports[i].w)
        .collect()
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
/// Fixed columns' fractions are ignored by [`viewports`], so they're left untouched.
pub fn sanitize_layout(cols: &mut [Column]) {
    for c in cols.iter_mut() {
        if c.fixed_width_px.is_none() && !(c.width_fraction.is_finite() && c.width_fraction > 0.0) {
            c.width_fraction = MIN_FLEX_FRACTION;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn next_instance_id_is_one_past_the_max() {
        assert_eq!(next_instance_id(&[]), 0, "empty strip starts at 0");
        assert_eq!(next_instance_id(&cols(&[0.5, 0.5])), 2, "ids 0,1 → 2");
        let with_gap = vec![Column::new(5, module_type::WAVEFORM, 1.0)];
        assert_eq!(next_instance_id(&with_gap), 6, "single id 5 → 6");
        let unsorted = vec![
            Column::new(2, module_type::WAVEFORM, 1.0),
            Column::new(0, module_type::WAVEFORM, 1.0),
            Column::new(9, module_type::WAVEFORM, 1.0),
            Column::new(3, module_type::WAVEFORM, 1.0),
        ];
        assert_eq!(next_instance_id(&unsorted), 10, "one past the max regardless of order");
    }

    fn cols(fracs: &[f32]) -> Vec<Column> {
        fracs
            .iter()
            .enumerate()
            .map(|(i, &f)| Column::new(i as u64, module_type::WAVEFORM, f))
            .collect()
    }

    #[test]
    fn insert_column_lands_right_after_and_allocates_id() {
        let mut v = cols(&[0.5, 0.5]); // ids 0, 1
        let at = insert_column(&mut v, 0, module_type::OSCILLOSCOPE);
        assert_eq!(at, 1, "lands right after the clicked column");
        assert_eq!(v.iter().map(|c| c.instance_id).collect::<Vec<_>>(), vec![0, 2, 1]);
        assert_eq!(v[1].module_type, module_type::OSCILLOSCOPE);
        assert!(v[1].fixed_width_px.is_none(), "inserts as flex; the caller reconciles intrinsic width");
    }

    #[test]
    fn insert_column_clamps_after_past_end() {
        let mut v = cols(&[0.5, 0.5]);
        let at = insert_column(&mut v, 99, module_type::WAVEFORM);
        assert_eq!(at, 2, "an out-of-range `after` appends at the end");
        assert_eq!(v.len(), 3);
    }

    #[test]
    fn insert_column_max_after_appends_without_overflow() {
        // usize::MAX is the empty-strip / no-column "append" sentinel — saturating_add must not panic.
        let mut empty: Vec<Column> = Vec::new();
        assert_eq!(insert_column(&mut empty, usize::MAX, module_type::WAVEFORM), 0);
        assert_eq!(empty.len(), 1);
        let mut two = cols(&[0.5, 0.5]);
        assert_eq!(insert_column(&mut two, usize::MAX, module_type::WAVEFORM), 2, "appends at the end");
    }

    #[test]
    fn remove_column_drops_at_index_and_returns_id() {
        let mut v = cols(&[0.3, 0.3, 0.4]); // ids 0, 1, 2
        assert_eq!(remove_column(&mut v, 1), Some(1));
        assert_eq!(v.iter().map(|c| c.instance_id).collect::<Vec<_>>(), vec![0, 2]);
    }

    #[test]
    fn remove_column_out_of_range_is_none() {
        let mut v = cols(&[0.5, 0.5]);
        assert_eq!(remove_column(&mut v, 9), None);
        assert_eq!(v.len(), 2, "nothing removed");
    }

    #[test]
    fn remove_to_empty_is_allowed() {
        let mut v = cols(&[1.0]);
        assert_eq!(remove_column(&mut v, 0), Some(0));
        assert!(v.is_empty(), "an empty strip is a valid state (shows the right-click hint)");
    }

    #[test]
    fn two_equal_columns_split_evenly() {
        let vp = viewports(&cols(&[0.5, 0.5]), 800.0, 600.0, 1.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 400.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 });
    }

    #[test]
    fn odd_width_last_column_absorbs_rounding_no_gap() {
        // W=801: col0 floors to 400, col1 absorbs the rest → 401. No gap, no overlap, sum == 801.
        let vp = viewports(&cols(&[0.5, 0.5]), 801.0, 600.0, 1.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 400.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 400.0, y: 0.0, w: 401.0, h: 600.0 });
        let total: f32 = vp.iter().map(|r| r.w).sum();
        assert_eq!(total, 801.0);
    }

    #[test]
    fn three_uneven_columns_tile_exactly() {
        let vp = viewports(&cols(&[0.25, 0.25, 0.5]), 800.0, 600.0, 1.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 200.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 200.0, y: 0.0, w: 200.0, h: 600.0 });
        assert_eq!(vp[2], Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 });
    }

    #[test]
    fn fractions_are_normalized_by_their_sum() {
        // Fractions 1.0+1.0 (sum 2) behave like 0.5+0.5.
        let vp = viewports(&cols(&[1.0, 1.0]), 800.0, 600.0, 1.0);
        assert_eq!(vp[0].w, 400.0);
        assert_eq!(vp[1].w, 400.0);
    }

    #[test]
    fn empty_layout_yields_no_viewports() {
        assert!(viewports(&[], 800.0, 600.0, 1.0).is_empty());
    }

    #[test]
    fn fixed_column_keeps_its_px_and_flex_takes_the_rest() {
        let cols = vec![
            Column::new(0, module_type::WAVEFORM, 1.0),
            Column::fixed(1, module_type::LOUDNESS, 200.0),
        ];
        // scale 1.0: loudness is exactly 200 px, the waveform fills the rest, no gap.
        let vp = viewports(&cols, 800.0, 600.0, 1.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 600.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 600.0, y: 0.0, w: 200.0, h: 600.0 });
        // scale 2.0 (Retina): the fixed column doubles in physical px, waveform absorbs the rest.
        let vp2 = viewports(&cols, 1600.0, 600.0, 2.0);
        assert_eq!(vp2[1].w, 400.0);
        assert_eq!(vp2[0].w, 1200.0);
    }

    #[test]
    fn fixed_wider_than_surface_clamps_rects_to_surface() {
        // Window narrower than the fixed column's scaled width: the flex column collapses to 0 and
        // the fixed column is CLIPPED to the surface — never a rect past the right edge (an
        // out-of-attachment set_viewport/set_scissor_rect is a wgpu validation error).
        let cols = vec![
            Column::new(0, module_type::WAVEFORM, 1.0),
            Column::fixed(1, module_type::LOUDNESS, 200.0),
        ];
        let vp = viewports(&cols, 250.0, 600.0, 2.0); // fixed claims 400 > 250
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 0.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 0.0, y: 0.0, w: 250.0, h: 600.0 });
        let total: f32 = vp.iter().map(|r| r.w).sum();
        assert!(total <= 250.0);
    }

    #[test]
    fn all_fixed_layout_tiles_exactly() {
        // No flexing column at all: the last column absorbs the remainder so the strip still tiles.
        let cols = vec![
            Column::fixed(0, module_type::LOUDNESS, 100.0),
            Column::fixed(1, module_type::LOUDNESS, 100.0),
        ];
        let vp = viewports(&cols, 300.0, 600.0, 1.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 100.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 100.0, y: 0.0, w: 200.0, h: 600.0 });
    }

    #[test]
    fn reconcile_repins_fixed_widths_from_live_modules() {
        // A legacy persisted layout (Loudness as a flex column, pre-fixed-width builds) and a stale
        // pinned width (knobs changed since the session was saved) BOTH re-pin to the live module's
        // intrinsic width; columns whose module reports None keep their persisted shape.
        let mut legacy = vec![
            Column::new(0, module_type::WAVEFORM, 0.85),
            Column::new(1, module_type::LOUDNESS, 0.15), // legacy flex Loudness
        ];
        reconcile_fixed_widths(&mut legacy, &[None, Some(160.0)]);
        assert!(legacy[0].fixed_width_px.is_none(), "Waveform keeps flexing");
        assert_eq!(legacy[1].fixed_width_px, Some(160.0), "legacy flex column migrates to fixed");

        let mut stale = vec![Column::fixed(1, module_type::LOUDNESS, 151.6)];
        reconcile_fixed_widths(&mut stale, &[Some(168.4)]);
        assert_eq!(stale[0].fixed_width_px, Some(168.4), "stale pinned width re-derives");
    }

    #[test]
    fn default_layout_flexes_waveform_around_fixed_loudness() {
        let l = default_layout();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].module_type, module_type::WAVEFORM);
        assert_eq!(l[1].module_type, module_type::LOUDNESS);
        assert!(l[0].fixed_width_px.is_none(), "Waveform flexes to fill the window");
        assert!(l[1].fixed_width_px.is_some(), "Loudness owns its (intrinsic) fixed width");
    }

    // ── E1: pure hit-testing / reorder / sanitize helpers (Phase E input routing, ADR 0004) ──

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
    fn draggable_seams_are_only_the_flex_flex_boundaries() {
        // Three flex columns → two draggable seams at their boundaries.
        let three = cols(&[0.25, 0.25, 0.5]);
        let vp = viewports(&three, 800.0, 600.0, 1.0); // [0..200],[200..400],[400..800]
        assert_eq!(draggable_seams(&three, &vp), vec![200.0, 400.0]);

        // flex | fixed: no draggable seam (the fixed column owns its edge).
        let flexfixed = vec![
            Column::new(0, module_type::WAVEFORM, 1.0),
            Column::fixed(1, module_type::LOUDNESS, 200.0),
        ];
        let vp2 = viewports(&flexfixed, 800.0, 600.0, 1.0);
        assert!(draggable_seams(&flexfixed, &vp2).is_empty());

        // flex | flex | fixed: only the first seam is draggable.
        let mixed = vec![
            Column::new(0, module_type::WAVEFORM, 0.5),
            Column::new(1, module_type::WAVEFORM, 0.5),
            Column::fixed(2, module_type::LOUDNESS, 160.0),
        ];
        let vp3 = viewports(&mixed, 800.0, 600.0, 1.0); // flex split 640 → [0..320],[320..640],[640..800]
        assert_eq!(draggable_seams(&mixed, &vp3), vec![320.0]);
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
    fn remap_identity_when_active_is_layout() {
        let layout = cols(&[0.5, 0.5]);
        let vps = viewports(&layout, 800.0, 600.0, 1.0);
        // No drag: active IS the committed layout, so the remap is identity.
        assert_eq!(remap_to_layout_order(&layout, &layout, &vps), vps);
    }

    #[test]
    fn remap_follows_provisional_permutation() {
        let layout = cols(&[0.5, 0.5]); // ids 0, 1 — modules render in this order
        let active = vec![layout[1].clone(), layout[0].clone()]; // provisional swap: [1, 0]
        let a = Rect { x: 0.0, y: 0.0, w: 400.0, h: 600.0 };
        let b = Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 };
        let active_vps = vec![a, b];
        // Column 0 sits in active slot 1 → gets rect B; column 1 sits in active slot 0 → rect A.
        assert_eq!(remap_to_layout_order(&layout, &active, &active_vps), vec![b, a]);
    }

    #[test]
    fn remap_falls_back_to_identity_on_unknown_id() {
        let layout = cols(&[0.5, 0.5]); // ids 0, 1
        // active is missing id 1 (replaced by a stranger) — column 1 keeps its own-index rect, no panic.
        let active = vec![layout[0].clone(), Column::new(7, module_type::WAVEFORM, 0.5)];
        let a = Rect { x: 0.0, y: 0.0, w: 400.0, h: 600.0 };
        let b = Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 };
        assert_eq!(remap_to_layout_order(&layout, &active, &[a, b]), vec![a, b]);
    }

    #[test]
    fn remap_never_panics_when_active_is_shorter_than_layout() {
        // The invariant (active/active_vps same length as layout) can't be violated by the live code,
        // but the remap must DEGRADE, not panic, if a future change ever slips it — a render-thread
        // panic kills the editor. A 3-column layout against a 2-entry active → the orphan gets an
        // empty rect (draws nothing) instead of an out-of-bounds index.
        let layout = cols(&[0.34, 0.33, 0.33]); // ids 0, 1, 2
        let a = Rect { x: 0.0, y: 0.0, w: 400.0, h: 600.0 };
        let b = Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 };
        let out = remap_to_layout_order(&layout, &layout[..2], &[a, b]);
        assert_eq!(out, vec![a, b, Rect { x: 0.0, y: 0.0, w: 0.0, h: 0.0 }]);
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
}
