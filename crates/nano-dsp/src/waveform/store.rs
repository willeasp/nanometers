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
//!
//! `WaveStore` owns this state (ring + accumulator + filterbank) and the GPU-free column building,
//! so it's unit-testable without a wgpu device — `WaveformModule` is a thin GPU wrapper over it.

use super::color::Filterbank;

/// Base-bin width (ADR 0002). Sample-rate-independent: 0.5 ms → 2000 bins/sec.
pub const BIN_SECONDS: f32 = 0.0005;

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

/// The Waveform's GPU-free state: the base-bin ring, the in-progress accumulator, the 3-band
/// filterbank, and the column building. Folds samples in, hands back merged display columns.
///
/// Display columns are anchored to ABSOLUTE bin boundaries (multiples of bins-per-column) via the
/// monotonic `bins_closed` counter — so a column covers a fixed absolute bin range and its merged
/// value is frozen once computed. A feature therefore keeps constant height as it scrolls; the grid
/// just shifts by whole columns. (`tests::feature_keeps_constant_height_as_it_scrolls` pins this.)
pub struct WaveStore {
    bins: Vec<BaseBin>,
    bins_closed: u64,
    /// Total samples ever folded — drives the continuous (sub-bin) scroll position.
    samples_folded: u64,

    sample_rate: f32,
    samples_per_bin: usize,
    band_low_hz: f32,
    band_high_hz: f32,
    filterbank: Option<Filterbank>,

    acc_min: [f32; 2],
    acc_max: [f32; 2],
    acc_sumsq: [f32; 2],
    acc_band_sumsq: [f32; 3],
    acc_count: usize,

    linear: Vec<BaseBin>, // reused scratch for oldest→newest linearization
}

impl WaveStore {
    pub fn new(window_bins: usize, band_low_hz: f32, band_high_hz: f32) -> Self {
        let window_bins = window_bins.max(1);
        Self {
            bins: vec![BaseBin::SILENCE; window_bins],
            bins_closed: 0,
            samples_folded: 0,
            sample_rate: 0.0,
            samples_per_bin: 0,
            band_low_hz,
            band_high_hz,
            filterbank: None,
            acc_min: [f32::INFINITY; 2],
            acc_max: [f32::NEG_INFINITY; 2],
            acc_sumsq: [0.0; 2],
            acc_band_sumsq: [0.0; 3],
            acc_count: 0,
            linear: vec![BaseBin::SILENCE; window_bins],
        }
    }

    /// `true` once a sample rate is known and samples can be folded.
    pub fn is_active(&self) -> bool {
        self.samples_per_bin > 0
    }

    /// (Re)configure for a sample rate — recomputes bins size + rebuilds the filterbank. No-op if
    /// unchanged. A rate of 0 leaves the store idle.
    pub fn set_sample_rate(&mut self, sample_rate: f32) {
        if sample_rate <= 0.0 || sample_rate == self.sample_rate {
            return;
        }
        self.sample_rate = sample_rate;
        self.samples_per_bin = (sample_rate * BIN_SECONDS).round().max(1.0) as usize;
        self.filterbank = Some(Filterbank::new(sample_rate, self.band_low_hz, self.band_high_hz));
        // A new rate changes samples-per-bin, so old bins no longer align to the new grid. Clear
        // the history and both clocks together — otherwise the sample-clock (`samples_folded`,
        // drives the scroll position) and the bin-clock (`bins_closed`, anchors the columns) would
        // desync and blank/sweep the right edge.
        self.bins.iter_mut().for_each(|b| *b = BaseBin::SILENCE);
        self.bins_closed = 0;
        self.samples_folded = 0;
        self.reset_accumulator();
    }

    fn reset_accumulator(&mut self) {
        self.acc_min = [f32::INFINITY; 2];
        self.acc_max = [f32::NEG_INFINITY; 2];
        self.acc_sumsq = [0.0; 2];
        self.acc_band_sumsq = [0.0; 3];
        self.acc_count = 0;
    }

    /// Fold one stereo frame into the current base bin (closing it on a 0.5 ms boundary).
    pub fn push(&mut self, l: f32, r: f32) {
        if self.samples_per_bin == 0 {
            return;
        }
        self.samples_folded = self.samples_folded.wrapping_add(1); // matches bins_closed
        // Spectral color (ADR 0001): filter the mono sum, accumulate per-band power.
        let mono = 0.5 * (l + r);
        let bands = self
            .filterbank
            .as_mut()
            .map(|fb| fb.process(mono))
            .unwrap_or([0.0; 3]);

        self.acc_min[0] = self.acc_min[0].min(l);
        self.acc_max[0] = self.acc_max[0].max(l);
        self.acc_sumsq[0] += l * l;
        self.acc_min[1] = self.acc_min[1].min(r);
        self.acc_max[1] = self.acc_max[1].max(r);
        self.acc_sumsq[1] += r * r;
        for k in 0..3 {
            self.acc_band_sumsq[k] += bands[k] * bands[k];
        }
        self.acc_count += 1;
        if self.acc_count >= self.samples_per_bin {
            self.close_bin();
        }
    }

    fn close_bin(&mut self) {
        let n = self.acc_count.max(1) as f32;
        let env = [
            ChannelEnvelope { min: self.acc_min[0], max: self.acc_max[0], mean_square: self.acc_sumsq[0] / n },
            ChannelEnvelope { min: self.acc_min[1], max: self.acc_max[1], mean_square: self.acc_sumsq[1] / n },
        ];
        let band_ms = [
            self.acc_band_sumsq[0] / n,
            self.acc_band_sumsq[1] / n,
            self.acc_band_sumsq[2] / n,
        ];
        let pos = (self.bins_closed % self.bins.len() as u64) as usize;
        self.bins[pos] = BaseBin { env, band_ms };
        self.bins_closed = self.bins_closed.wrapping_add(1);
        self.reset_accumulator();
    }

    pub fn samples_per_bin(&self) -> usize {
        self.samples_per_bin
    }

    /// Total samples folded since the last reset — the live scroll edge is `samples_folded /
    /// samples_per_col` columns.
    pub fn samples_folded(&self) -> u64 {
        self.samples_folded
    }

    /// Samples that have closed into base bins (excludes the in-progress accumulator). A display
    /// column whose sample range ends within this is fully populated.
    pub fn closed_samples(&self) -> u64 {
        self.bins_closed * self.samples_per_bin as u64
    }

    /// Merge the base bins into `num` display columns (oldest→newest), each spanning
    /// `samples_per_col` samples (refresh-derived, so the scroll can advance by whole pixels at a
    /// rate that matches the audio). The rightmost column is absolute column `rightmost_col`; column
    /// `k` covers samples `[k·spc, (k+1)·spc)`, mapped to the overlapping base bins (≤0.5 ms edge
    /// slop). Anchored to absolute sample boundaries, so a feature's column value is frozen as it
    /// scrolls. Columns off the ring (or before recording started) read as silence.
    pub fn build_columns(
        &mut self,
        num: usize,
        samples_per_col: f64,
        rightmost_col: i64,
    ) -> Vec<BaseBin> {
        let num = num.max(1);
        let spb = self.samples_per_bin.max(1) as f64;
        let n = self.bins.len();
        let total = self.bins_closed as i128;
        let head = (self.bins_closed % n as u64) as usize;
        for i in 0..n {
            self.linear[i] = self.bins[(head + i) % n];
        }
        let win_start = total - n as i128; // oldest absolute bin still in the ring

        let mut out = Vec::with_capacity(num);
        for c in 0..num {
            let abs_col = (rightmost_col - (num as i64 - 1 - c as i64)) as f64;
            let start_sample = abs_col * samples_per_col;
            // Base bins overlapping this column's sample range (floor/ceil → ≤1 bin of slop).
            let lo_bin = (start_sample / spb).floor() as i128;
            let hi_bin = ((start_sample + samples_per_col) / spb).ceil() as i128;
            let lo = lo_bin.max(win_start);
            let hi = hi_bin.min(total);
            out.push(if lo < hi {
                merge(&self.linear[(lo - win_start) as usize..(hi - win_start) as usize])
            } else {
                BaseBin::SILENCE
            });
        }
        out
    }

    /// Merge the base bins overlapping the absolute sample range `[lo_sample, hi_sample)` into one
    /// column. This is the primitive for the incremental scroll: each render builds its new columns
    /// from explicit sample ranges (sizes flexing to track the clock drift), so a built column is
    /// immutable — it never re-maps as it scrolls. Ranges off the ring (or before recording started)
    /// read as silence; partial overlap clamps to what's available.
    pub fn merge_sample_range(&self, lo_sample: i64, hi_sample: i64) -> BaseBin {
        let spb = self.samples_per_bin.max(1) as f64;
        let n = self.bins.len() as i64;
        let total = self.bins_closed as i64;
        let win_start = total - n; // oldest absolute bin still in the ring
        let lo = ((lo_sample as f64 / spb).floor() as i64).max(win_start);
        let hi = ((hi_sample as f64 / spb).ceil() as i64).min(total);
        if lo >= hi {
            return BaseBin::SILENCE;
        }
        let mut env = [
            ChannelEnvelope { min: f32::INFINITY, max: f32::NEG_INFINITY, mean_square: 0.0 },
            ChannelEnvelope { min: f32::INFINITY, max: f32::NEG_INFINITY, mean_square: 0.0 },
        ];
        let mut band_ms = [0.0f32; 3];
        for abs in lo..hi {
            let b = &self.bins[abs.rem_euclid(n) as usize];
            for ch in 0..2 {
                env[ch].min = env[ch].min.min(b.env[ch].min);
                env[ch].max = env[ch].max.max(b.env[ch].max);
                env[ch].mean_square += b.env[ch].mean_square;
            }
            for k in 0..3 {
                band_ms[k] += b.band_ms[k];
            }
        }
        let inv = 1.0 / (hi - lo) as f32;
        for ch in 0..2 {
            env[ch].mean_square *= inv;
        }
        for k in 0..3 {
            band_ms[k] *= inv;
        }
        BaseBin { env, band_ms }
    }
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
    fn sample_counters_track_pushes() {
        const SR: f32 = 48000.0;
        let mut s = WaveStore::new(2000, 250.0, 4000.0);
        s.set_sample_rate(SR);
        let spb = s.samples_per_bin() as u64; // 24 @ 48k
        assert_eq!(s.samples_folded(), 0);
        for _ in 0..240 {
            s.push(0.0, 0.0);
        }
        assert_eq!(s.samples_folded(), 240);
        // closed_samples counts only whole bins (240/24 = 10 bins closed → 240 samples closed).
        assert_eq!(s.closed_samples(), 10 * spb);
        // A half-open bin: 12 more samples → folded 252, but still 10 closed bins.
        for _ in 0..12 {
            s.push(0.0, 0.0);
        }
        assert_eq!(s.samples_folded(), 252);
        assert_eq!(s.closed_samples(), 10 * spb);
    }

    /// Feed a distinctive loud "kick", capture its display column's height, scroll it left by
    /// feeding more silence, and assert the SAME kick has the SAME height at the new position —
    /// the property the sample-anchored columns guarantee, exercised through the Module's real
    /// anchor path (`floor(samples_folded / samples_per_col)` → `build_columns`).
    #[test]
    fn feature_keeps_constant_height_as_it_scrolls() {
        const SR: f32 = 48000.0;
        const COLUMNS: usize = 200;
        const SPC: f64 = 240.0; // samples per column
        let spb = (SR * BIN_SECONDS).round() as usize;
        let mut s = WaveStore::new(2000, 250.0, 4000.0); // 1 s window
        s.set_sample_rate(SR);

        let silence = |s: &mut WaveStore, bins: usize| {
            for _ in 0..bins * spb {
                s.push(0.0, 0.0);
            }
        };

        silence(&mut s, 100);
        for _ in 0..6 * spb {
            s.push(0.9, -0.9); // the kick: a few full-scale bins
        }
        silence(&mut s, 40);

        let rightmost1 = (s.samples_folded() as f64 / SPC).floor() as i64;
        let cols1 = s.build_columns(COLUMNS, SPC, rightmost1);
        let (idx1, kick1) = cols1
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.env[0].max.partial_cmp(&b.1.env[0].max).unwrap())
            .unwrap();
        assert!(kick1.env[0].max > 0.5, "kick should be a tall column");

        silence(&mut s, 300); // scroll it well to the left
        let rightmost2 = (s.samples_folded() as f64 / SPC).floor() as i64;
        let cols2 = s.build_columns(COLUMNS, SPC, rightmost2);
        let (idx2, kick2) = cols2
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.env[0].max.partial_cmp(&b.1.env[0].max).unwrap())
            .unwrap();

        assert!(rightmost2 > rightmost1, "anchor advanced");
        assert!(idx2 < idx1, "kick must have scrolled left: {idx1} -> {idx2}");
        assert!(
            (kick1.env[0].max - kick2.env[0].max).abs() < 1e-6
                && (kick1.env[0].min - kick2.env[0].min).abs() < 1e-6,
            "kick height must be stable as it scrolls: was max={} min={}, now max={} min={}",
            kick1.env[0].max,
            kick1.env[0].min,
            kick2.env[0].max,
            kick2.env[0].min
        );
    }

    /// Same constant-height guarantee, but with a FRACTIONAL samples-per-column (the real case:
    /// `sample_rate / (px_per_frame · fps)` is almost never a whole multiple of samples-per-bin).
    /// The peak's ABSOLUTE column is independent of the scroll anchor, so its merged range — and
    /// thus its height — is identical at both positions despite the ≤1-bin floor/ceil edge slop.
    #[test]
    fn feature_keeps_constant_height_with_fractional_spc() {
        const SR: f32 = 48000.0;
        const COLUMNS: usize = 300;
        const SPC: f64 = 183.75; // fractional: not a whole number of 24-sample bins
        let spb = (SR * BIN_SECONDS).round() as usize;
        let mut s = WaveStore::new(4000, 250.0, 4000.0);
        s.set_sample_rate(SR);

        let silence = |s: &mut WaveStore, bins: usize| {
            for _ in 0..bins * spb {
                s.push(0.0, 0.0);
            }
        };

        silence(&mut s, 120);
        for _ in 0..6 * spb {
            s.push(0.9, -0.9);
        }
        silence(&mut s, 30);

        let rightmost1 = (s.samples_folded() as f64 / SPC).floor() as i64;
        let cols1 = s.build_columns(COLUMNS, SPC, rightmost1);
        let (idx1, kick1) = cols1
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.env[0].max.partial_cmp(&b.1.env[0].max).unwrap())
            .unwrap();
        assert!(kick1.env[0].max > 0.5, "kick should be a tall column");

        silence(&mut s, 400);
        let rightmost2 = (s.samples_folded() as f64 / SPC).floor() as i64;
        let cols2 = s.build_columns(COLUMNS, SPC, rightmost2);
        let (idx2, kick2) = cols2
            .iter()
            .enumerate()
            .max_by(|a, b| a.1.env[0].max.partial_cmp(&b.1.env[0].max).unwrap())
            .unwrap();

        assert!(idx2 < idx1, "kick must have scrolled left: {idx1} -> {idx2}");
        assert!(
            (kick1.env[0].max - kick2.env[0].max).abs() < 1e-6
                && (kick1.env[0].min - kick2.env[0].min).abs() < 1e-6,
            "fractional-spc kick height must be stable: was max={} min={}, now max={} min={}",
            kick1.env[0].max,
            kick1.env[0].min,
            kick2.env[0].max,
            kick2.env[0].min
        );
    }

    #[test]
    fn merge_sample_range_picks_out_the_right_samples() {
        const SR: f32 = 48000.0;
        let mut s = WaveStore::new(4000, 250.0, 4000.0);
        s.set_sample_rate(SR);
        let spb = s.samples_per_bin(); // 24
        // 100 silent bins, one loud bin, then more silence.
        for _ in 0..100 * spb {
            s.push(0.0, 0.0);
        }
        for _ in 0..spb {
            s.push(0.9, -0.9);
        }
        for _ in 0..50 * spb {
            s.push(0.0, 0.0);
        }

        // The loud bin's exact sample range comes back loud…
        let loud = s.merge_sample_range((100 * spb) as i64, (101 * spb) as i64);
        assert!((loud.env[0].max - 0.9).abs() < 1e-6, "L max {}", loud.env[0].max);
        assert!((loud.env[1].min + 0.9).abs() < 1e-6, "R min {}", loud.env[1].min);
        // …a silent range comes back silent…
        let quiet = s.merge_sample_range((10 * spb) as i64, (11 * spb) as i64);
        assert_eq!(quiet.env[0].max, 0.0);
        // …and a range past the live edge (future / unclosed) reads as silence.
        assert_eq!(
            s.merge_sample_range((10_000 * spb) as i64, (10_001 * spb) as i64),
            BaseBin::SILENCE
        );
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
