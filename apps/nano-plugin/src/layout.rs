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

#[cfg(test)]
mod tests {
    use super::*;

    fn cols(fracs: &[f32]) -> Vec<Column> {
        fracs
            .iter()
            .enumerate()
            .map(|(i, &f)| Column::new(i as u64, module_type::WAVEFORM, f))
            .collect()
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
}
