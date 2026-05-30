//! Waveform base-bin store (ADRs 0002 / 0007).
//!
//! The Waveform folds incoming samples into a ring of **0.5 ms base bins**, then merges the visible
//! run of bins down to pixel columns at draw time. Storing at a fixed base resolution (rather than
//! at display resolution) makes window resize and zoom a cheap re-merge instead of a raw re-scan,
//! and 0.5 ms is the floor below which "envelope" stops being meaningful (it's the Oscilloscope's
//! job below that — ADR 0002).
//!
//! Each base bin keeps, **per channel** (L, R), the sample min / max / mean-square, plus a **single
//! shared** set of 3 band mean-squares from the mono sum (ADR 0001 — one set, not per channel).
//! Mean-square is stored, never RMS: averaging RMS isn't associative, so we average mean-squares
//! across a column and take the `sqrt` only at draw (ADR 0002).

/// Per-channel amplitude envelope over a bin.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ChannelEnvelope {
    pub min: f32,
    pub max: f32,
    pub mean_square: f32,
}

impl ChannelEnvelope {
    pub const SILENCE: Self = Self {
        min: 0.0,
        max: 0.0,
        mean_square: 0.0,
    };
}

/// One 0.5 ms base bin: per-channel envelope (index 0 = L, 1 = R) + 3 shared band mean-squares.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct BaseBin {
    pub env: [ChannelEnvelope; 2],
    pub band_ms: [f32; 3],
}

impl BaseBin {
    pub const SILENCE: Self = Self {
        env: [ChannelEnvelope::SILENCE; 2],
        band_ms: [0.0; 3],
    };
}

/// Merge a run of uniform (equal-sample-count) base bins into one bin — collapsing the base bins
/// that fall under a pixel column at draw. `min` = min, `max` = max, and every mean-square (per
/// channel and per band) is the **equal-weight mean** of the bins' values, since base bins are all
/// the same 0.5 ms size. Order-independent; an empty run is silence.
pub fn merge(bins: &[BaseBin]) -> BaseBin {
    if bins.is_empty() {
        return BaseBin::SILENCE;
    }
    let mut out = BaseBin {
        env: [
            ChannelEnvelope { min: f32::INFINITY, max: f32::NEG_INFINITY, mean_square: 0.0 },
            ChannelEnvelope { min: f32::INFINITY, max: f32::NEG_INFINITY, mean_square: 0.0 },
        ],
        band_ms: [0.0; 3],
    };
    for b in bins {
        for ch in 0..2 {
            out.env[ch].min = out.env[ch].min.min(b.env[ch].min);
            out.env[ch].max = out.env[ch].max.max(b.env[ch].max);
            out.env[ch].mean_square += b.env[ch].mean_square;
        }
        for band in 0..3 {
            out.band_ms[band] += b.band_ms[band];
        }
    }
    let inv_n = 1.0 / bins.len() as f32;
    for ch in 0..2 {
        out.env[ch].mean_square *= inv_n;
    }
    for band in 0..3 {
        out.band_ms[band] *= inv_n;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn bin(
        lmin: f32,
        lmax: f32,
        lms: f32,
        rmin: f32,
        rmax: f32,
        rms: f32,
        bands: [f32; 3],
    ) -> BaseBin {
        BaseBin {
            env: [
                ChannelEnvelope { min: lmin, max: lmax, mean_square: lms },
                ChannelEnvelope { min: rmin, max: rmax, mean_square: rms },
            ],
            band_ms: bands,
        }
    }

    #[test]
    fn merge_empty_is_silence() {
        assert_eq!(merge(&[]), BaseBin::SILENCE);
    }

    #[test]
    fn merge_single_bin_is_identity() {
        let b = bin(-0.5, 0.5, 0.25, -0.3, 0.4, 0.16, [0.1, 0.2, 0.3]);
        assert_eq!(merge(&[b]), b);
    }

    #[test]
    fn merge_conserves_minmax_and_averages_mean_squares() {
        let a = bin(-0.5, 0.5, 0.25, -0.2, 0.6, 0.10, [0.10, 0.20, 0.30]);
        let b = bin(-0.8, 0.3, 0.16, -0.9, 0.1, 0.40, [0.20, 0.20, 0.20]);
        let m = merge(&[a, b]);
        // min/max are the extremes across both bins, per channel.
        assert_eq!(m.env[0].min, -0.8);
        assert_eq!(m.env[0].max, 0.5);
        assert_eq!(m.env[1].min, -0.9);
        assert_eq!(m.env[1].max, 0.6);
        // mean-square is the equal-weight mean.
        assert!((m.env[0].mean_square - 0.205).abs() < 1e-6);
        assert!((m.env[1].mean_square - 0.25).abs() < 1e-6);
        assert!((m.band_ms[0] - 0.15).abs() < 1e-6);
        assert!((m.band_ms[1] - 0.20).abs() < 1e-6);
        assert!((m.band_ms[2] - 0.25).abs() < 1e-6);
    }

    #[test]
    fn merge_is_order_independent() {
        let a = bin(-0.5, 0.5, 0.25, -0.2, 0.6, 0.10, [0.10, 0.20, 0.30]);
        let b = bin(-0.8, 0.3, 0.16, -0.9, 0.1, 0.40, [0.20, 0.20, 0.20]);
        let c = bin(-0.1, 0.9, 0.50, -0.4, 0.2, 0.05, [0.30, 0.10, 0.10]);
        assert_eq!(merge(&[a, b, c]), merge(&[c, a, b]));
    }
}
