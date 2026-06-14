//! Multi-resolution FFT spectrum for the Spectrum Analyzer (ADR 0009 — platform-free, shared with
//! the TUI/iOS).
//!
//! "Exact, no coarse bands" means a single linear FFT won't do: it's fine at high frequencies but
//! coarse in the bass on a log axis (few bins per octave) unless it's huge — and a huge FFT is
//! sluggish everywhere. So we run THREE real FFTs — long (bass), medium, short (treble) — each
//! Blackman-Harris windowed and normalized to dBFS so a full-scale sine reads 0 dB *regardless of
//! size*. Each log-frequency display point reads whichever band gives ≥ a target bins/octave there
//! (the shortest such band → best time response), peak-preserving across the bins in its cell. The
//! stitched curve is fine at every frequency AND responsive, with no jump at the crossovers.

use std::sync::Arc;

use realfft::num_complex::Complex;
use realfft::{RealFftPlanner, RealToComplex};

/// FFT sizes, longest (best bass resolution) → shortest (best treble response).
const FFT_SIZES: [usize; 3] = [32768, 8192, 2048];
/// A band of size `N` is "usable" above `target · fs / N` (where an octave holds ≥ target bins). Each
/// display point uses the SHORTEST usable band, for the best time response at that frequency.
const BINS_PER_OCT_TARGET: f32 = 24.0;
/// Display frequency range; the top is clamped to just under Nyquist.
const F_LO: f32 = 20.0;
const F_HI: f32 = 20_000.0;
/// dB floor used as the silence / empty value (the display maps a configurable floor; this is the raw
/// clamp so logs never produce -inf).
const DB_FLOOR: f32 = -140.0;

/// Blackman-Harris (4-term) window — low spectral leakage, so a tone shows a clean narrow peak.
fn blackman_harris(n: usize) -> Vec<f32> {
    let (a0, a1, a2, a3) = (0.35875, 0.48829, 0.14128, 0.01168);
    let denom = (n.max(2) - 1) as f32;
    (0..n)
        .map(|i| {
            let x = std::f32::consts::TAU * i as f32 / denom;
            a0 - a1 * x.cos() + a2 * (2.0 * x).cos() - a3 * (3.0 * x).cos()
        })
        .collect()
}

/// One resolution: a windowed real FFT over a sliding window, hop-updated, magnitudes in dBFS.
struct ResBand {
    fft: Arc<dyn RealToComplex<f32>>,
    size: usize,
    window: Vec<f32>,
    norm: f32, // 2 / Σwindow — coherent-gain single-sided normalization (full-scale sine → 0 dB)
    ring: Vec<f32>,
    write: usize,
    hop: usize,
    since_hop: usize,
    input: Vec<f32>,
    output: Vec<Complex<f32>>,
    power: Vec<f32>, // normalized power |X[k]·norm|² per bin (size/2 + 1)
}

impl ResBand {
    fn new(planner: &mut RealFftPlanner<f32>, size: usize) -> Self {
        let fft = planner.plan_fft_forward(size);
        let window = blackman_harris(size);
        let win_sum: f32 = window.iter().sum();
        let nbins = size / 2 + 1;
        Self {
            input: fft.make_input_vec(),
            output: fft.make_output_vec(),
            fft,
            size,
            window,
            norm: 2.0 / win_sum.max(1e-9),
            ring: vec![0.0; size],
            write: 0,
            // 75% overlap, but cap the long FFT's hop so the bass still refreshes promptly.
            hop: (size / 4).min(2048),
            since_hop: 0,
            power: vec![0.0; nbins],
        }
    }

    fn push(&mut self, x: f32) {
        self.ring[self.write] = x;
        self.write = (self.write + 1) % self.size;
        self.since_hop += 1;
        if self.since_hop >= self.hop {
            self.since_hop = 0;
            self.compute();
        }
    }

    fn compute(&mut self) {
        // Copy the ring in time order (oldest→newest) and window it.
        let split = self.write;
        for i in 0..self.size {
            let s = self.ring[(split + i) % self.size];
            self.input[i] = s * self.window[i];
        }
        if self.fft.process(&mut self.input, &mut self.output).is_err() {
            return;
        }
        for (k, c) in self.output.iter().enumerate() {
            let mag = c.norm() * self.norm;
            self.power[k] = mag * mag;
        }
    }

    /// dBFS for the cell `[f_lo, f_hi]`: the MAX power over the bins the cell overlaps. Peak-preserving
    /// — a tone always lands on its (coherent-gain-normalized) peak bin → reads 0 dBFS regardless of
    /// where it falls between display points or bins, and a swept tone never drops between points. The
    /// cell is grown to floor(f_lo)…ceil(f_hi) so a narrow cell still catches the peak bin.
    fn cell_max_db(&self, f_lo: f32, f_hi: f32, sr: f32) -> f32 {
        let to_bin = |f: f32| f * self.size as f32 / sr;
        let k_lo = (to_bin(f_lo).floor().max(0.0) as usize).min(self.power.len() - 1);
        let k_hi = (to_bin(f_hi).ceil() as usize).min(self.power.len() - 1);
        let pmax = (k_lo..=k_hi).map(|k| self.power[k]).fold(0.0_f32, f32::max);
        (10.0 * (pmax + 1e-20).log10()).max(DB_FLOOR)
    }
}

/// Hermite smoothstep on `[a, b]`.
fn smoothstep(a: f32, b: f32, x: f32) -> f32 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// The multi-resolution spectrum. Push mono samples; read the stitched log-frequency dB curve.
pub struct MultiResSpectrum {
    sample_rate: f32,
    bands: Vec<ResBand>,
    point_freq: Vec<f32>, // center frequency of each display point (log-spaced)
    /// Crossover frequencies between the 3 bands (32k→8k, 8k→2k) — centers of the blend transitions.
    trans: [f32; 2],
    display_db: Vec<f32>,
}

impl MultiResSpectrum {
    /// Log-spaced display points across [20 Hz, ~Nyquist] at ~`BINS_PER_OCT_TARGET` points per octave
    /// — the *real* resolution, so each cell spans ≈1 FFT bin (the GPU smooth-renders to per-pixel).
    /// A band whose window exceeds the available history is still fine (it fills from zeros until warm).
    pub fn new(sample_rate: f64) -> Self {
        let sr = sample_rate as f32;
        let f_hi = F_HI.min(sr * 0.5 * 0.99).max(F_LO * 2.0);
        let octaves = (f_hi / F_LO).log2();
        let n_points = ((BINS_PER_OCT_TARGET * octaves).round() as usize).max(2);

        let mut planner = RealFftPlanner::<f32>::new();
        let bands: Vec<ResBand> = FFT_SIZES.iter().map(|&n| ResBand::new(&mut planner, n)).collect();

        let ratio = (f_hi / F_LO).powf(1.0 / (n_points - 1) as f32);
        let point_freq: Vec<f32> = (0..n_points).map(|p| F_LO * ratio.powi(p as i32)).collect();

        // Crossover frequency for a band transition: where the SHORTER band's bin (fs/N) first fits a
        // display cell (cell ≈ f·(ratio−1)). Above it the shorter (faster) band is used; the blend in
        // `magnitudes_db` crossfades around it so the bandwidth difference ramps instead of stepping.
        let cell_frac = ratio - 1.0;
        let crossover = |n: usize| (sr / (n as f32 * cell_frac)).clamp(F_LO * 1.5, f_hi * 0.7);
        let trans = [crossover(FFT_SIZES[1]), crossover(FFT_SIZES[2])];

        Self { sample_rate: sr, bands, point_freq, trans, display_db: vec![DB_FLOOR; n_points] }
    }

    pub fn n_points(&self) -> usize {
        self.point_freq.len()
    }

    pub fn point_freq(&self) -> &[f32] {
        &self.point_freq
    }

    pub fn push(&mut self, mono: f32) {
        for b in &mut self.bands {
            b.push(mono);
        }
    }

    /// The stitched dBFS curve. Each point is a partition-of-unity blend of the three bands' per-bin
    /// dB at its frequency: a tone reads ~0 dB in every band, so the blend is 0 dB (tone-exact); the
    /// noise floor, which differs by FFT bandwidth, ramps smoothly across the crossovers instead of
    /// stepping. Width of the crossfade, in octaves:
    const BLEND_HALF_OCT: f32 = 0.4;

    pub fn magnitudes_db(&mut self) -> &[f32] {
        let sr = self.sample_rate;
        let (lt0, lt1) = (self.trans[0].log2(), self.trans[1].log2());
        let h = Self::BLEND_HALF_OCT;
        let n = self.point_freq.len();
        for p in 0..n {
            let f = self.point_freq[p];
            // Geometric cell bounds (midpoints to the neighbors).
            let f_lo = if p > 0 { (self.point_freq[p - 1] * f).sqrt() } else { f * 0.99 };
            let f_hi = if p + 1 < n { (f * self.point_freq[p + 1]).sqrt() } else { f * 1.01 };
            // Long band (32k) fades out at trans[0]; short band (2k) fades in at trans[1]; the medium
            // band (8k) takes the remainder — a smooth partition (sums to 1) so a tone (≈0 dB in every
            // band) blends to 0 dB while the bandwidth-dependent noise floor ramps instead of stepping.
            let lf = f.log2();
            let w_long = 1.0 - smoothstep(lt0 - h, lt0 + h, lf);
            let w_short = smoothstep(lt1 - h, lt1 + h, lf);
            let w_mid = (1.0 - w_long - w_short).max(0.0);
            self.display_db[p] = w_long * self.bands[0].cell_max_db(f_lo, f_hi, sr)
                + w_mid * self.bands[1].cell_max_db(f_lo, f_hi, sr)
                + w_short * self.bands[2].cell_max_db(f_lo, f_hi, sr);
        }
        &self.display_db
    }
}

/// Display ballistics over the stitched dB curve: a live trace (fast attack, eased release) plus a
/// peak-hold line that holds a transient then falls slowly. Release/attack are tunable (the knobs).
pub struct SpectrumDisplay {
    pub live: Vec<f32>,
    pub peak: Vec<f32>,
    hold_left: Vec<f32>, // seconds of peak-hold remaining per point
}

/// Seconds the peak line holds a new max before it starts falling.
const PEAK_HOLD_S: f32 = 1.2;
/// Peak-line fall rate once the hold expires.
const PEAK_FALL_DB_PER_S: f32 = 24.0;

impl SpectrumDisplay {
    pub fn new(n: usize) -> Self {
        Self { live: vec![DB_FLOOR; n], peak: vec![DB_FLOOR; n], hold_left: vec![0.0; n] }
    }

    /// Advance one frame. `mag` is the instantaneous stitched curve; `dt` seconds since the last
    /// frame; `attack_ms`/`release_ms` set the live trace's rise/fall time constants.
    pub fn update(&mut self, mag: &[f32], dt: f32, attack_ms: f32, release_ms: f32) {
        let coeff = |ms: f32| 1.0 - (-dt * 1000.0 / ms.max(1.0)).exp(); // 1-pole approach per frame
        let (a, r) = (coeff(attack_ms), coeff(release_ms));
        for i in 0..self.live.len().min(mag.len()) {
            let m = mag[i];
            // Asymmetric 1-pole: fast toward a rising value, eased toward a falling one.
            let c = if m >= self.live[i] { a } else { r };
            self.live[i] += (m - self.live[i]) * c;

            if self.live[i] >= self.peak[i] {
                self.peak[i] = self.live[i];
                self.hold_left[i] = PEAK_HOLD_S;
            } else if self.hold_left[i] > 0.0 {
                self.hold_left[i] -= dt;
            } else {
                self.peak[i] = (self.peak[i] - PEAK_FALL_DB_PER_S * dt).max(self.live[i]);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f64 = 48_000.0;

    /// Push `secs` of a full-scale sine at `freq`, then return the stitched dB curve + point freqs.
    fn run_sine(freq: f32, secs: f32) -> (Vec<f32>, Vec<f32>) {
        let mut s = MultiResSpectrum::new(SR);
        let n = (secs * SR as f32) as usize;
        for i in 0..n {
            let x = (i as f32 * freq / SR as f32 * std::f32::consts::TAU).sin();
            s.push(x);
        }
        let db = s.magnitudes_db().to_vec();
        (db, s.point_freq().to_vec())
    }

    fn peak_point(db: &[f32]) -> usize {
        db.iter()
            .enumerate()
            .max_by(|a, b| a.1.partial_cmp(b.1).unwrap())
            .map(|(i, _)| i)
            .unwrap()
    }

    #[test]
    fn full_scale_sine_reads_0db_at_its_frequency() {
        let (db, freqs) = run_sine(1000.0, 1.0);
        let p = peak_point(&db);
        assert!((freqs[p] - 1000.0).abs() / 1000.0 < 0.03, "peak at {} Hz, want 1000", freqs[p]);
        assert!((db[p] - 0.0).abs() < 0.6, "full-scale 1 kHz should read ~0 dB, got {}", db[p]);
    }

    #[test]
    fn normalization_is_consistent_across_bands() {
        // A tone in the SHORT-FFT band (5 kHz) and one in the LONG-FFT band (50 Hz), both full-scale,
        // must both read ~0 dB — proving the per-size coherent-gain normalization lines up.
        let (db_hi, _) = run_sine(5000.0, 1.0);
        let (db_lo, _) = run_sine(50.0, 1.0);
        let hi = db_hi[peak_point(&db_hi)];
        let lo = db_lo[peak_point(&db_lo)];
        assert!((hi - 0.0).abs() < 1.0, "5 kHz peak {hi} dB");
        assert!((lo - 0.0).abs() < 1.0, "50 Hz peak {lo} dB");
        assert!((hi - lo).abs() < 1.0, "bands disagree: {hi} vs {lo} dB");
    }

    #[test]
    fn low_frequency_is_resolved_finely() {
        // 40 Hz: only the 32k band is usable here. Its 1.46 Hz bins place the peak within ~2 Hz — a
        // single small FFT (23 Hz bins) could be off by 10+ Hz.
        let (db, freqs) = run_sine(40.0, 1.5);
        let p = peak_point(&db);
        assert!((freqs[p] - 40.0).abs() < 2.0, "40 Hz resolved to {} Hz", freqs[p]);
    }

    #[test]
    fn tones_read_0db_across_the_whole_spectrum() {
        // The real "exact, no coarse bands" guarantee: a full-scale tone reads ~0 dB at EVERY
        // frequency — through both crossovers and at off-bin frequencies — not just at 1 kHz. This is
        // what a single small FFT (coarse bass) or a mis-stitched multi-res (crossover dips) would fail.
        for &f in &[35.0_f32, 60.0, 140.0, 300.0, 800.0, 2000.0, 7000.0, 15000.0] {
            let (db, _) = run_sine(f, 1.5);
            let peak = db[peak_point(&db)];
            assert!((peak - 0.0).abs() < 1.5, "{f} Hz tone read {peak} dB (want ~0)");
        }
    }

    #[test]
    fn live_attacks_fast_releases_slow() {
        let mut d = SpectrumDisplay::new(1);
        let dt = 1.0 / 60.0;
        for _ in 0..20 {
            d.update(&[-10.0], dt, 5.0, 300.0); // settle at -10
        }
        assert!((d.live[0] + 10.0).abs() < 1.0, "settled near -10, got {}", d.live[0]);
        // Attack: jump the target up; one frame gets most of the way (fast).
        d.update(&[0.0], dt, 5.0, 300.0);
        assert!(d.live[0] > -3.0, "fast attack should leap toward 0, got {}", d.live[0]);
        // Release: drop the target far; one frame barely falls (slow, 300 ms).
        d.update(&[-60.0], dt, 5.0, 300.0);
        assert!(d.live[0] > -10.0, "slow release should still be high, got {}", d.live[0]);
        // …and after a couple seconds it settles low.
        for _ in 0..150 {
            d.update(&[-60.0], dt, 5.0, 300.0);
        }
        assert!(d.live[0] < -50.0, "release settles low eventually, got {}", d.live[0]);
    }

    #[test]
    fn peak_holds_then_decays() {
        let mut d = SpectrumDisplay::new(1);
        let dt = 1.0 / 60.0;
        for _ in 0..15 {
            d.update(&[0.0], dt, 5.0, 50.0); // drive live + peak up to ~0
        }
        let p0 = d.peak[0];
        assert!(p0 > -1.0, "peak tracked the live up to ~0, got {p0}");
        // Drop the signal: live falls; the peak holds above it during the hold window.
        for _ in 0..30 {
            d.update(&[-60.0], dt, 5.0, 50.0);
        }
        assert!(d.peak[0] > d.live[0] + 5.0, "peak still held above the live trace");
        // Past the hold + decay, the peak has fallen well below its held value.
        for _ in 0..300 {
            d.update(&[-60.0], dt, 5.0, 50.0);
        }
        assert!(d.peak[0] < p0 - 10.0, "peak eventually decays from its held value");
    }

    #[test]
    fn silence_is_floor_not_nan() {
        let mut s = MultiResSpectrum::new(SR);
        for _ in 0..100_000 {
            s.push(0.0);
        }
        let db = s.magnitudes_db();
        assert!(db.iter().all(|v| v.is_finite() && *v <= DB_FLOOR + 1.0), "silence should be at the floor");
    }
}
