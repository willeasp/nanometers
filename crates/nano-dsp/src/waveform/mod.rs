//! The Waveform's platform-free pieces (ADRs 0001 / 0002 / 0007).
//!
//! [`store`] owns the base-bin envelope store + sample-anchored column building; [`color`] owns the
//! 3-band filterbank and the band→RGB mapping. This module also holds the pure **scroll control
//! law** — `choose_px_per_frame` and `consume_samples` — the arithmetic that turns clock drift into
//! per-pixel sample counts instead of motion. All GPU-free and unit-tested; the wgpu `WaveformModule`
//! in `nano-render` is a thin wrapper that calls into these.

pub mod color;
pub mod store;

/// Integer pixels the contour moves per render: round the ideal continuous rate
/// (`columns / (window · fps)`) to a whole pixel, at least 1. Robust — a fps estimate off by a few
/// percent picks the same integer — and the per-pixel sample count carries the exact rate.
pub fn choose_px_per_frame(columns: usize, window_seconds: f64, fps: f64) -> i64 {
    if window_seconds <= 0.0 || fps <= 0.0 {
        return 1;
    }
    ((columns as f64 / (window_seconds * fps)).round() as i64).max(1)
}

/// Samples to consume into this frame's new columns. Pure (no GPU), so the control law is testable.
/// It's the smoothed arrival rate (`avg_arrival`) nudged by a gentle proportional term toward holding
/// the reservoir (`closed − drawn edge`) at `target` — the loop that absorbs clock drift into the
/// per-pixel sample count instead of the motion (slew, never step). Clamped ≥ 0 and ≤ what's actually
/// closed (`available`), so we never build a column from audio that hasn't arrived.
pub fn consume_samples(
    avg_arrival: f64,
    reservoir: f64,
    target: f64,
    gain: f64,
    available: f64,
) -> f64 {
    let want = avg_arrival + gain * (reservoir - target);
    want.clamp(0.0, available.max(0.0))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn px_per_frame_rounds_to_a_whole_step() {
        // 1200 px over 5 s at 120 Hz → 1200/600 = 2.0 → 2 px/frame.
        assert_eq!(choose_px_per_frame(1200, 5.0, 120.0), 2);
        // Same window at 60 Hz → 1200/300 = 4.0 → 4 px/frame (half the rate, twice as many).
        assert_eq!(choose_px_per_frame(1200, 5.0, 60.0), 4);
        // Never zero, even on a tiny/odd window.
        assert_eq!(choose_px_per_frame(50, 5.0, 120.0), 1);
    }

    // ── consume_samples: the reservoir control loop (samples → this render's new columns) ──
    // Reference: avg_arrival 366 samples/render, target reservoir 1000 samples, gain 0.02.

    #[test]
    fn consume_equals_arrival_at_the_target() {
        // Reservoir exactly at target → consume exactly the arrival rate (steady state, no drift).
        assert!((consume_samples(366.0, 1000.0, 1000.0, 0.02, 5000.0) - 366.0).abs() < 1e-9);
    }

    #[test]
    fn consume_speeds_up_when_audio_runs_ahead() {
        // Reservoir above target (audio crept ahead) → consume a touch more to catch up.
        let c = consume_samples(366.0, 1500.0, 1000.0, 0.02, 5000.0);
        assert!((c - (366.0 + 0.02 * 500.0)).abs() < 1e-9, "got {c}"); // 376
        assert!(c > 366.0 && c < 366.0 + 50.0, "gentle: a fraction of a sample per pixel");
    }

    #[test]
    fn consume_eases_off_when_reservoir_is_low() {
        // Reservoir below target → consume a touch less so it refills.
        let c = consume_samples(366.0, 600.0, 1000.0, 0.02, 5000.0);
        assert!((c - (366.0 + 0.02 * -400.0)).abs() < 1e-9, "got {c}"); // 358
    }

    #[test]
    fn consume_never_exceeds_available_or_goes_negative() {
        // Can't build from audio that hasn't closed yet…
        assert_eq!(consume_samples(366.0, 1000.0, 1000.0, 0.02, 100.0), 100.0);
        // …and never runs the cursor backwards.
        assert_eq!(consume_samples(10.0, 0.0, 5000.0, 0.02, 5000.0), 0.0);
    }
}
