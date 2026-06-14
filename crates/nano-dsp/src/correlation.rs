//! Smoothed stereo phase-correlation for the Stereometer Module (ADR 0009 — platform-free, shared so
//! the TUI and iOS get it too).
//!
//! A standard correlation meter: leaky-integrated sums of `L·R`, `L²`, `R²`; the normalized ratio
//! `c = Σlr / sqrt(Σll · Σrr)` is the Pearson-style correlation in `[−1, +1]` (+1 = mono/in-phase,
//! 0 = uncorrelated, −1 = anti-phase). The normalization cancels the integrator's scale, so no
//! `(1 − decay)` factor is needed. The per-sample leak sets the ballistics (~300 ms window).

/// Leaky-integration time constant — the correlation's effective averaging window.
const TIME_CONSTANT_S: f64 = 0.3;

/// A running, smoothed stereo phase-correlation. Push samples; read [`value`](Self::value).
pub struct StereoCorrelation {
    ll: f64,
    rr: f64,
    lr: f64,
    /// Per-sample leak coefficient in `(0, 1)`; smaller = shorter window.
    decay: f64,
}

impl StereoCorrelation {
    /// `sample_rate` in Hz. A non-positive rate falls back to a sane decay so it never divides by zero.
    pub fn new(sample_rate: f64) -> Self {
        let decay = if sample_rate > 0.0 {
            (-1.0 / (TIME_CONSTANT_S * sample_rate)).exp()
        } else {
            0.999
        };
        Self { ll: 0.0, rr: 0.0, lr: 0.0, decay }
    }

    /// Fold one stereo sample into the running correlation.
    pub fn push(&mut self, l: f32, r: f32) {
        let (l, r) = (l as f64, r as f64);
        self.ll = self.ll * self.decay + l * l;
        self.rr = self.rr * self.decay + r * r;
        self.lr = self.lr * self.decay + l * r;
    }

    /// The smoothed correlation in `[−1, +1]`; `0.0` when either side is silent (never `NaN` from 0/0).
    pub fn value(&self) -> f32 {
        let denom = (self.ll * self.rr).sqrt();
        if denom <= 1e-12 {
            0.0
        } else {
            (self.lr / denom).clamp(-1.0, 1.0) as f32
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const SR: f64 = 48_000.0;

    /// Feed `n` samples from a stereo generator and return the settled correlation.
    fn settle(n: usize, mut g: impl FnMut(usize) -> (f32, f32)) -> f32 {
        let mut c = StereoCorrelation::new(SR);
        for i in 0..n {
            let (l, r) = g(i);
            c.push(l, r);
        }
        c.value()
    }

    fn sine(i: usize) -> f32 {
        (i as f64 * 440.0 / SR * std::f64::consts::TAU).sin() as f32
    }

    #[test]
    fn in_phase_mono_is_plus_one() {
        // L == R → perfectly correlated.
        let c = settle(48_000, |i| (sine(i), sine(i)));
        assert!((c - 1.0).abs() < 1e-3, "mono should read +1, got {c}");
    }

    #[test]
    fn anti_phase_is_minus_one() {
        // L == −R → perfectly anti-correlated.
        let c = settle(48_000, |i| (sine(i), -sine(i)));
        assert!((c + 1.0).abs() < 1e-3, "anti-phase should read −1, got {c}");
    }

    #[test]
    fn decorrelated_is_near_zero() {
        // Two independent zero-mean noise sources → ~0. Tiny LCGs, seeded differently, mapped to
        // [−1, 1) so each has zero mean (else a nonzero-mean pair would read correlated).
        let mut sl: u32 = 0x1234_5678;
        let mut sr: u32 = 0x9E37_79B9;
        let mut noise = |s: &mut u32| {
            *s = s.wrapping_mul(1_103_515_245).wrapping_add(12_345);
            (*s >> 9) as f32 / (1u32 << 22) as f32 - 1.0 // [−1, 1)
        };
        let c = settle(200_000, |_| (noise(&mut sl), noise(&mut sr)));
        assert!(c.abs() < 0.15, "decorrelated should read ~0, got {c}");
    }

    #[test]
    fn silence_is_zero_not_nan() {
        let c = settle(1_000, |_| (0.0, 0.0));
        assert_eq!(c, 0.0);
        assert!(c.is_finite());
    }

    #[test]
    fn always_within_unit_range() {
        // A messy mix of gains/phases never escapes [−1, 1].
        let c = settle(50_000, |i| (sine(i) * 0.7, sine(i + 13) * 1.5));
        assert!((-1.0..=1.0).contains(&c), "out of range: {c}");
    }
}
