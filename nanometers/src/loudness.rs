//! Loudness measurement — ITU-R BS.1770 / EBU R128.
//!
//! GUI-side DSP core (per ADR 0002 all metering is screen-side). Hand-rolled per ADR 0006;
//! `ebur128` is a dev-dependency used only as a test oracle, never linked into the plugin.
//! See `docs/specs/loudness-module.md` for the full contract.
//!
//! Structure: every K-weighted sample is squared and accumulated into 100 ms bins. Momentary is
//! the last 4 bins (400 ms), Short-term the last 30 (3 s), and each new bin closes a 400 ms gating
//! block (4 bins, stepped every 100 ms = 75 % overlap) feeding the gated Integrated measurement.
//! Bin-quantization means M/S lag the true sliding window by up to 100 ms on transients — on the
//! steady reference signals the conformance tests use, the values match `ebur128` to well within
//! the 0.1 LU tolerance.

use std::collections::VecDeque;

/// Channel handling for the BS.1770 channel-weighted sum. Mono measures a single channel
/// (weight 1.0); stereo sums L + R. The plugin duplicates a mono input to L = R, so summing that
/// would read +3 LU hot — hence the explicit mode rather than always summing.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Channels {
    Mono,
    Stereo,
}

const ABSOLUTE_GATE_LUFS: f64 = -70.0;
const RELATIVE_GATE_LU: f64 = 10.0;
const MOMENTARY_BINS: usize = 4; // 400 ms
const SHORT_TERM_BINS: usize = 30; // 3 s
const GATE_BLOCK_BINS: usize = 4; // 400 ms gating block
/// 24 h of 100 ms blocks — a runaway guard, not an expected bound (see spec).
const MAX_BLOCKS: usize = 24 * 3600 * 10;

/// One biquad section, Direct Form I. Coefficients are shared across channels; state is not.
#[derive(Clone, Copy, Default)]
struct Biquad {
    b0: f64,
    b1: f64,
    b2: f64,
    a1: f64,
    a2: f64,
}

#[derive(Clone, Copy, Default)]
struct BiquadState {
    x1: f64,
    x2: f64,
    y1: f64,
    y2: f64,
}

impl Biquad {
    fn process(&self, s: &mut BiquadState, x: f64) -> f64 {
        let y = self.b0 * x + self.b1 * s.x1 + self.b2 * s.x2 - self.a1 * s.y1 - self.a2 * s.y2;
        s.x2 = s.x1;
        s.x1 = x;
        s.y2 = s.y1;
        s.y1 = y;
        y
    }
}

/// The two K-weighting stages for a given sample rate: a high-shelf "head" filter and the RLB
/// high-pass. Coefficients follow the libebur128 design (which reproduces the BS.1770 48 kHz
/// reference values) so we match the `ebur128` oracle at any rate.
fn k_weighting(fs: f64) -> (Biquad, Biquad) {
    use std::f64::consts::PI;

    // Stage 1 — shelving boost.
    let f0 = 1681.974450955533;
    let g = 3.999843853973347;
    let q = 0.7071752369554196;
    let k = (PI * f0 / fs).tan();
    let vh = 10f64.powf(g / 20.0);
    let vb = vh.powf(0.4996667741545416);
    let a0 = 1.0 + k / q + k * k;
    let stage1 = Biquad {
        b0: (vh + vb * k / q + k * k) / a0,
        b1: 2.0 * (k * k - vh) / a0,
        b2: (vh - vb * k / q + k * k) / a0,
        a1: 2.0 * (k * k - 1.0) / a0,
        a2: (1.0 - k / q + k * k) / a0,
    };

    // Stage 2 — RLB high-pass.
    let f0 = 38.13547087602444;
    let q = 0.5003270373238773;
    let k = (PI * f0 / fs).tan();
    let denom = 1.0 + k / q + k * k;
    let stage2 = Biquad {
        b0: 1.0,
        b1: -2.0,
        b2: 1.0,
        a1: 2.0 * (k * k - 1.0) / denom,
        a2: (1.0 - k / q + k * k) / denom,
    };

    (stage1, stage2)
}

/// BS.1770 loudness from a channel-weighted mean square. Returns `-inf` for non-positive input.
fn lufs(z: f64) -> f64 {
    if z > 0.0 {
        -0.691 + 10.0 * z.log10()
    } else {
        f64::NEG_INFINITY
    }
}

/// Hand-rolled BS.1770 loudness meter. Feed it frames; read Momentary / Short-term / Integrated.
pub struct LoudnessDsp {
    channels: Channels,
    stage1: Biquad,
    stage2: Biquad,
    /// Per-channel filter state (index 0 = L, 1 = R).
    st1: [BiquadState; 2],
    st2: [BiquadState; 2],

    /// Sum of squared K-weighted samples in the current 100 ms bin, per channel.
    bin_sumsq: [f64; 2],
    bin_count: usize,
    samples_per_bin: usize,

    /// Channel-weighted mean square of each recent 100 ms bin (most recent last), capped at the
    /// Short-term window. Serves Momentary (last 4) and Short-term (last 30).
    recent_bins: VecDeque<f64>,
    /// Channel-weighted mean square of each 400 ms gating block since the last reset.
    blocks: VecDeque<f64>,
}

impl LoudnessDsp {
    pub fn new(sample_rate: f64, channels: Channels) -> Self {
        let (stage1, stage2) = k_weighting(sample_rate);
        Self {
            channels,
            stage1,
            stage2,
            st1: Default::default(),
            st2: Default::default(),
            bin_sumsq: [0.0; 2],
            bin_count: 0,
            samples_per_bin: (sample_rate * 0.1).round() as usize,
            recent_bins: VecDeque::with_capacity(SHORT_TERM_BINS + 1),
            blocks: VecDeque::new(),
        }
    }

    /// Fold one stereo frame into the measurement. In mono mode only the left channel is used.
    pub fn push_frame(&mut self, l: f32, r: f32) {
        let yl = self
            .stage2
            .process(&mut self.st2[0], self.stage1.process(&mut self.st1[0], l as f64));
        self.bin_sumsq[0] += yl * yl;

        if self.channels == Channels::Stereo {
            let yr = self
                .stage2
                .process(&mut self.st2[1], self.stage1.process(&mut self.st1[1], r as f64));
            self.bin_sumsq[1] += yr * yr;
        }

        self.bin_count += 1;
        if self.bin_count >= self.samples_per_bin {
            self.close_bin();
        }
    }

    fn close_bin(&mut self) {
        let n = self.bin_count as f64;
        let z = match self.channels {
            Channels::Mono => self.bin_sumsq[0] / n,
            Channels::Stereo => self.bin_sumsq[0] / n + self.bin_sumsq[1] / n,
        };

        self.recent_bins.push_back(z);
        while self.recent_bins.len() > SHORT_TERM_BINS {
            self.recent_bins.pop_front();
        }

        // Each closed bin completes a fresh 400 ms gating block from the last 4 bins.
        if self.recent_bins.len() >= GATE_BLOCK_BINS {
            let start = self.recent_bins.len() - GATE_BLOCK_BINS;
            let sum: f64 = self.recent_bins.iter().skip(start).sum();
            self.blocks.push_back(sum / GATE_BLOCK_BINS as f64);
            if self.blocks.len() > MAX_BLOCKS {
                self.blocks.pop_front();
            }
        }

        self.bin_sumsq = [0.0; 2];
        self.bin_count = 0;
    }

    /// Clears the measurement (bins + gating blocks). Filter state is kept so K-weighting stays
    /// continuous with the signal across a reset.
    pub fn reset(&mut self) {
        self.bin_sumsq = [0.0; 2];
        self.bin_count = 0;
        self.recent_bins.clear();
        self.blocks.clear();
    }

    fn mean_square_last(&self, n: usize) -> Option<f64> {
        if self.recent_bins.is_empty() {
            return None;
        }
        let take = n.min(self.recent_bins.len());
        let start = self.recent_bins.len() - take;
        let sum: f64 = self.recent_bins.iter().skip(start).sum();
        Some(sum / take as f64)
    }

    pub fn momentary_lufs(&self) -> f32 {
        self.mean_square_last(MOMENTARY_BINS)
            .map(lufs)
            .unwrap_or(f64::NEG_INFINITY) as f32
    }

    pub fn short_term_lufs(&self) -> f32 {
        self.mean_square_last(SHORT_TERM_BINS)
            .map(lufs)
            .unwrap_or(f64::NEG_INFINITY) as f32
    }

    /// Two-stage gated Integrated loudness over all blocks since reset: absolute gate at
    /// −70 LUFS, then a relative gate 10 LU below the abs-gated mean.
    pub fn integrated_lufs(&self) -> f32 {
        let abs_gated: Vec<f64> = self
            .blocks
            .iter()
            .copied()
            .filter(|&z| lufs(z) >= ABSOLUTE_GATE_LUFS)
            .collect();
        if abs_gated.is_empty() {
            return f32::NEG_INFINITY;
        }

        let mean_abs = abs_gated.iter().sum::<f64>() / abs_gated.len() as f64;
        let rel_threshold = lufs(mean_abs) - RELATIVE_GATE_LU;

        let rel_gated: Vec<f64> = abs_gated
            .iter()
            .copied()
            .filter(|&z| lufs(z) >= rel_threshold)
            .collect();
        if rel_gated.is_empty() {
            return f32::NEG_INFINITY;
        }

        let mean_rel = rel_gated.iter().sum::<f64>() / rel_gated.len() as f64;
        lufs(mean_rel) as f32
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use ebur128::{EbuR128, Mode};

    const FS: f64 = 48000.0;
    const TOL: f64 = 0.1; // LU

    fn run_ours(interleaved: &[f32]) -> LoudnessDsp {
        let mut d = LoudnessDsp::new(FS, Channels::Stereo);
        for f in interleaved.chunks_exact(2) {
            d.push_frame(f[0], f[1]);
        }
        d
    }

    fn ebu(interleaved: &[f32]) -> (f64, f64, f64) {
        let mut e = EbuR128::new(2, FS as u32, Mode::M | Mode::S | Mode::I).unwrap();
        e.add_frames_f32(interleaved).unwrap();
        (
            e.loudness_momentary().unwrap(),
            e.loudness_shortterm().unwrap(),
            e.loudness_global().unwrap(),
        )
    }

    fn sine_stereo(freq: f64, amp: f64, secs: f64) -> Vec<f32> {
        let n = (FS * secs) as usize;
        let mut v = Vec::with_capacity(n * 2);
        for i in 0..n {
            let s = (amp * (2.0 * std::f64::consts::PI * freq * i as f64 / FS).sin()) as f32;
            v.push(s);
            v.push(s);
        }
        v
    }

    fn white_stereo(amp: f64, secs: f64) -> Vec<f32> {
        let n = (FS * secs) as usize;
        let mut state: u64 = 0x1234_5678_9abc_def0;
        let mut v = Vec::with_capacity(n * 2);
        for _ in 0..n {
            state = state
                .wrapping_mul(6364136223846793005)
                .wrapping_add(1442695040888963407);
            let x = ((state >> 33) as f64 / (1u64 << 31) as f64 - 1.0) * amp;
            v.push(x as f32);
            v.push(x as f32);
        }
        v
    }

    #[test]
    fn sine_matches_ebur128() {
        let sig = sine_stereo(1000.0, 0.5, 5.0);
        let ours = run_ours(&sig);
        let (m, s, i) = ebu(&sig);
        assert!((ours.momentary_lufs() as f64 - m).abs() < TOL, "M {} vs {m}", ours.momentary_lufs());
        assert!((ours.short_term_lufs() as f64 - s).abs() < TOL, "S {} vs {s}", ours.short_term_lufs());
        assert!((ours.integrated_lufs() as f64 - i).abs() < TOL, "I {} vs {i}", ours.integrated_lufs());
    }

    #[test]
    fn white_noise_matches_ebur128() {
        let sig = white_stereo(0.3, 5.0);
        let ours = run_ours(&sig);
        let (m, s, i) = ebu(&sig);
        assert!((ours.momentary_lufs() as f64 - m).abs() < TOL, "M {} vs {m}", ours.momentary_lufs());
        assert!((ours.short_term_lufs() as f64 - s).abs() < TOL, "S {} vs {s}", ours.short_term_lufs());
        assert!((ours.integrated_lufs() as f64 - i).abs() < TOL, "I {} vs {i}", ours.integrated_lufs());
    }

    #[test]
    fn integrated_gates_trailing_silence() {
        let mut sig = sine_stereo(1000.0, 0.5, 4.0);
        sig.extend(std::iter::repeat(0.0f32).take((FS * 4.0) as usize * 2));
        let ours = run_ours(&sig);
        let (_, _, i) = ebu(&sig);
        assert!(
            (ours.integrated_lufs() as f64 - i).abs() < TOL,
            "I {} vs {i}",
            ours.integrated_lufs()
        );
    }
}
