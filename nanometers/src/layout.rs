//! Layout — the flat horizontal strip of resizable, reorderable Module columns (ADR 0003).
//!
//! The host owns the list and the geometry; each Module owns its opaque `config` blob. List order
//! is left→right placement. Widths are fractions so the strip scales cleanly on window resize.

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

/// One column in the strip: an instance of a Module type at a fractional width, plus the Module's
/// own opaque config blob (ADR 0003 — the host stores it, never reads it).
#[derive(Clone, Serialize, Deserialize, Debug, PartialEq)]
pub struct Column {
    pub instance_id: u64,
    pub module_type: String,
    pub width_fraction: f32,
    #[serde(default)]
    pub config: Vec<u8>,
}

impl Column {
    pub fn new(instance_id: u64, module_type: &str, width_fraction: f32) -> Self {
        Self {
            instance_id,
            module_type: module_type.to_string(),
            width_fraction,
            config: Vec::new(),
        }
    }
}

/// The app-default layout for a fresh instance with no persisted state (ADR 0003): Waveform +
/// Loudness side by side, each half width.
pub fn default_layout() -> Vec<Column> {
    // The Waveform earns the bulk of the width; Loudness is a compact readout strip.
    vec![
        Column::new(0, module_type::WAVEFORM, 0.78),
        Column::new(1, module_type::LOUDNESS, 0.22),
    ]
}

/// Integer-pixel column rectangles tiling the surface left→right with NO gaps or overlaps
/// (ADR 0003). Boundaries are floored from accumulated (normalized) fractions; the last column
/// absorbs rounding so the widths sum to exactly the surface width — and so each `Rect` converts
/// cleanly to wgpu's u32 `set_scissor_rect`. Fractions are normalized by their sum, so a strip
/// whose fractions don't quite total 1 still tiles fully.
pub fn viewports(cols: &[Column], surface_w: f32, surface_h: f32) -> Vec<Rect> {
    let n = cols.len();
    if n == 0 {
        return Vec::new();
    }
    let w = surface_w.max(0.0);
    let total: f32 = cols.iter().map(|c| c.width_fraction).sum();
    let total = if total > 0.0 { total } else { 1.0 };

    let mut rects = Vec::with_capacity(n);
    let mut acc = 0.0f32; // accumulated normalized fraction
    let mut prev_b = 0u32; // previous integer boundary
    for (i, c) in cols.iter().enumerate() {
        acc += c.width_fraction / total;
        // Last column snaps to exactly the surface width so the strip tiles with no gap/overlap.
        let b = if i == n - 1 {
            w.round() as u32
        } else {
            (acc * w).floor() as u32
        };
        let width = b.saturating_sub(prev_b);
        rects.push(Rect {
            x: prev_b as f32,
            y: 0.0,
            w: width as f32,
            h: surface_h,
        });
        prev_b = b;
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
        let vp = viewports(&cols(&[0.5, 0.5]), 800.0, 600.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 400.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 });
    }

    #[test]
    fn odd_width_last_column_absorbs_rounding_no_gap() {
        // W=801: col0 floors to 400, col1 absorbs the rest → 401. No gap, no overlap, sum == 801.
        let vp = viewports(&cols(&[0.5, 0.5]), 801.0, 600.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 400.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 400.0, y: 0.0, w: 401.0, h: 600.0 });
        let total: f32 = vp.iter().map(|r| r.w).sum();
        assert_eq!(total, 801.0);
    }

    #[test]
    fn three_uneven_columns_tile_exactly() {
        let vp = viewports(&cols(&[0.25, 0.25, 0.5]), 800.0, 600.0);
        assert_eq!(vp[0], Rect { x: 0.0, y: 0.0, w: 200.0, h: 600.0 });
        assert_eq!(vp[1], Rect { x: 200.0, y: 0.0, w: 200.0, h: 600.0 });
        assert_eq!(vp[2], Rect { x: 400.0, y: 0.0, w: 400.0, h: 600.0 });
    }

    #[test]
    fn fractions_are_normalized_by_their_sum() {
        // Fractions 1.0+1.0 (sum 2) behave like 0.5+0.5.
        let vp = viewports(&cols(&[1.0, 1.0]), 800.0, 600.0);
        assert_eq!(vp[0].w, 400.0);
        assert_eq!(vp[1].w, 400.0);
    }

    #[test]
    fn empty_layout_yields_no_viewports() {
        assert!(viewports(&[], 800.0, 600.0).is_empty());
    }

    #[test]
    fn default_layout_is_waveform_then_loudness() {
        let l = default_layout();
        assert_eq!(l.len(), 2);
        assert_eq!(l[0].module_type, module_type::WAVEFORM);
        assert_eq!(l[1].module_type, module_type::LOUDNESS);
        assert!(l[0].width_fraction > l[1].width_fraction, "Waveform gets the bulk");
        assert!((l[0].width_fraction + l[1].width_fraction - 1.0).abs() < 1e-6, "fractions sum to 1");
    }
}
