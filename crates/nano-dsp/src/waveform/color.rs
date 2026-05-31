//! Spectral coloring for the Waveform (ADR 0001).
//!
//! Two pieces: a **3-band filterbank** (biquad crossovers on the mono sum) that fills each base
//! bin's `band_ms`, and a **mapping** from those 3 band energies to one RGB color per column.
//!
//! The mapping is the ADR's load-bearing decision: a *dominant* band drives the hue (low = red,
//! mid = green, high = blue), and **spectral imbalance drives saturation** so balanced/broadband
//! content desaturates toward **white** — NOT naïve additive RGB, which makes bass + air read
//! magenta instead of white. Saturation here is "how much the top band stands out from the second"
//! (`top − second` fraction), which is 0 whenever energy is split across two-or-more bands (bass +
//! air, or uniform) → white, and 1 only when a single band dominates → its pure hue.

/// Pure band hues (low, mid, high). Tunable aesthetics (ADR 0001 says palette is dev-player
/// tuning); kept pure here so the mapping's behavior is unambiguous and testable.
const RED: [f32; 3] = [1.0, 0.0, 0.0];
const GREEN: [f32; 3] = [0.0, 1.0, 0.0];
const BLUE: [f32; 3] = [0.0, 0.0, 1.0];
/// Dim tint for a near-silent column (no meaningful spectrum).
const SILENT: [f32; 3] = [0.10, 0.16, 0.20];

fn lerp(a: f32, b: f32, t: f32) -> f32 {
    a + (b - a) * t
}

// ── 3-band filterbank (ADR 0001): RBJ biquad crossovers on the mono sum ──────────────────────

#[derive(Clone, Copy, Default)]
struct Biquad {
    b0: f32,
    b1: f32,
    b2: f32,
    a1: f32,
    a2: f32,
}

#[derive(Clone, Copy, Default)]
struct BiquadState {
    x1: f32,
    x2: f32,
    y1: f32,
    y2: f32,
}

impl Biquad {
    fn process(&self, s: &mut BiquadState, x: f32) -> f32 {
        let y = self.b0 * x + self.b1 * s.x1 + self.b2 * s.x2 - self.a1 * s.y1 - self.a2 * s.y2;
        s.x2 = s.x1;
        s.x1 = x;
        s.y2 = s.y1;
        s.y1 = y;
        y
    }
}

/// RBJ cookbook low-pass / high-pass, Q = 0.707 (Butterworth).
fn lowpass(fs: f32, f0: f32) -> Biquad {
    let (cos, alpha, _) = rbj_common(fs, f0);
    let a0 = 1.0 + alpha;
    Biquad {
        b0: ((1.0 - cos) / 2.0) / a0,
        b1: (1.0 - cos) / a0,
        b2: ((1.0 - cos) / 2.0) / a0,
        a1: (-2.0 * cos) / a0,
        a2: (1.0 - alpha) / a0,
    }
}

fn highpass(fs: f32, f0: f32) -> Biquad {
    let (cos, alpha, _) = rbj_common(fs, f0);
    let a0 = 1.0 + alpha;
    Biquad {
        b0: ((1.0 + cos) / 2.0) / a0,
        b1: (-(1.0 + cos)) / a0,
        b2: ((1.0 + cos) / 2.0) / a0,
        a1: (-2.0 * cos) / a0,
        a2: (1.0 - alpha) / a0,
    }
}

fn rbj_common(fs: f32, f0: f32) -> (f32, f32, f32) {
    use std::f32::consts::PI;
    let w0 = 2.0 * PI * f0 / fs;
    let cos = w0.cos();
    let sin = w0.sin();
    let alpha = sin / (2.0 * 0.7071068);
    (cos, alpha, w0)
}

/// 3-band split of the mono sum: low = LPF(low_hz), high = HPF(high_hz), mid = the band between
/// (HPF(low_hz) then LPF(high_hz)). Per-sample; the caller squares + accumulates into bin band_ms.
pub struct Filterbank {
    low: Biquad,
    low_st: BiquadState,
    high: Biquad,
    high_st: BiquadState,
    mid_hp: Biquad,
    mid_hp_st: BiquadState,
    mid_lp: Biquad,
    mid_lp_st: BiquadState,
}

impl Filterbank {
    pub fn new(fs: f32, low_hz: f32, high_hz: f32) -> Self {
        Self {
            low: lowpass(fs, low_hz),
            low_st: BiquadState::default(),
            high: highpass(fs, high_hz),
            high_st: BiquadState::default(),
            mid_hp: highpass(fs, low_hz),
            mid_hp_st: BiquadState::default(),
            mid_lp: lowpass(fs, high_hz),
            mid_lp_st: BiquadState::default(),
        }
    }

    /// Filtered `[low, mid, high]` outputs for one input sample.
    pub fn process(&mut self, x: f32) -> [f32; 3] {
        let low = self.low.process(&mut self.low_st, x);
        let high = self.high.process(&mut self.high_st, x);
        let mid_hp = self.mid_hp.process(&mut self.mid_hp_st, x);
        let mid = self.mid_lp.process(&mut self.mid_lp_st, mid_hp);
        [low, mid, high]
    }
}

/// Map 3 band mean-squares `[low, mid, high]` to an RGB color in `[0, 1]` (ADR 0001).
pub fn band_color(bands: [f32; 3]) -> [f32; 3] {
    let total = bands[0] + bands[1] + bands[2];
    if total <= 1e-12 {
        return SILENT;
    }
    let f = [bands[0] / total, bands[1] / total, bands[2] / total];

    // Saturation = how much the top band stands out from the second. 0 when two-or-more bands
    // tie (bass+air, uniform) → white; 1 when a single band dominates → pure hue.
    let mut sorted = f;
    sorted.sort_unstable_by(|a, b| b.partial_cmp(a).unwrap());
    let sat = (sorted[0] - sorted[1]).clamp(0.0, 1.0);

    // Hue = frac-weighted band colors, normalized so its brightest component is 1 (a saturated
    // color), then lerped toward white by (1 − sat).
    let mut hue = [
        f[0] * RED[0] + f[1] * GREEN[0] + f[2] * BLUE[0],
        f[0] * RED[1] + f[1] * GREEN[1] + f[2] * BLUE[1],
        f[0] * RED[2] + f[1] * GREEN[2] + f[2] * BLUE[2],
    ];
    let m = hue[0].max(hue[1]).max(hue[2]);
    if m > 0.0 {
        for c in &mut hue {
            *c /= m;
        }
    }

    [
        lerp(1.0, hue[0], sat),
        lerp(1.0, hue[1], sat),
        lerp(1.0, hue[2], sat),
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn single_band_gives_its_pure_hue() {
        let r = band_color([1.0, 0.0, 0.0]);
        assert!(r[0] > 0.9 && r[1] < 0.1 && r[2] < 0.1, "low → red, got {r:?}");
        let g = band_color([0.0, 1.0, 0.0]);
        assert!(g[1] > 0.9 && g[0] < 0.1 && g[2] < 0.1, "mid → green, got {g:?}");
        let b = band_color([0.0, 0.0, 1.0]);
        assert!(b[2] > 0.9 && b[0] < 0.1 && b[1] < 0.1, "high → blue, got {b:?}");
    }

    #[test]
    fn balanced_broadband_desaturates_to_white() {
        let w = band_color([1.0, 1.0, 1.0]);
        assert!(
            w[0] > 0.9 && w[1] > 0.9 && w[2] > 0.9,
            "balanced → white, got {w:?}"
        );
    }

    #[test]
    fn bass_plus_air_is_white_not_magenta() {
        // The ADR 0001 trap: low + high with no mid must read WHITE, not magenta. Magenta has
        // green ≈ 0; assert green stays high so it is not magenta.
        let c = band_color([1.0, 0.0, 1.0]);
        assert!(
            c[1] > 0.9,
            "bass+air must be white (high green), not magenta, got {c:?}"
        );
        assert!(c[0] > 0.9 && c[2] > 0.9, "and bright overall, got {c:?}");
    }

    #[test]
    fn dominant_band_with_some_spread_is_a_desaturated_hue() {
        // low-dominant but not pure → a pinkish red (red leads, but lifted toward white).
        let c = band_color([0.6, 0.2, 0.2]);
        assert!(c[0] >= c[1] && c[0] >= c[2], "red leads, got {c:?}");
        assert!(c[1] > 0.2 && c[2] > 0.2, "lifted toward white (not pure red), got {c:?}");
    }

    #[test]
    fn silence_is_the_dim_tint() {
        assert_eq!(band_color([0.0, 0.0, 0.0]), SILENT);
    }

    /// Run a sine of `freq` through the filterbank and return accumulated band powers.
    fn band_powers(freq: f32) -> [f32; 3] {
        const FS: f32 = 48000.0;
        let mut fb = Filterbank::new(FS, 250.0, 4000.0);
        let mut p = [0.0f32; 3];
        // Skip filter warm-up, then accumulate one chunk.
        for i in 0..9600 {
            let x = (2.0 * std::f32::consts::PI * freq * i as f32 / FS).sin();
            let b = fb.process(x);
            if i >= 4800 {
                for k in 0..3 {
                    p[k] += b[k] * b[k];
                }
            }
        }
        p
    }

    #[test]
    fn low_tone_lands_in_low_band() {
        let p = band_powers(100.0);
        assert!(p[0] > p[1] && p[0] > p[2], "100 Hz → low band, got {p:?}");
    }

    #[test]
    fn mid_tone_lands_in_mid_band() {
        let p = band_powers(1000.0);
        assert!(p[1] > p[0] && p[1] > p[2], "1 kHz → mid band, got {p:?}");
    }

    #[test]
    fn high_tone_lands_in_high_band() {
        let p = band_powers(12000.0);
        assert!(p[2] > p[0] && p[2] > p[1], "12 kHz → high band, got {p:?}");
    }
}
