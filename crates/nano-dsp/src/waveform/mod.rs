//! The Waveform's platform-free pieces (ADRs 0001 / 0002 / 0007).
//!
//! [`store`] owns the base-bin envelope store + sample-anchored column building; [`color`] owns the
//! 3-band filterbank and the band→RGB mapping. This module also holds the pure **scroll control
//! law** — `choose_px_per_frame` and `consume_samples` — the arithmetic that turns clock drift into
//! per-pixel sample counts instead of motion. The wgpu `WaveformModule` in the plugin is a thin
//! wrapper that calls into these.

pub mod color;
pub mod store;

/// Integer pixels the contour moves per render: round the ideal continuous rate
/// (`columns / (window · fps)`) to a whole pixel, at least 1.
pub fn choose_px_per_frame(columns: usize, window_seconds: f64, fps: f64) -> i64 {
    if window_seconds <= 0.0 || fps <= 0.0 {
        return 1;
    }
    ((columns as f64 / (window_seconds * fps)).round() as i64).max(1)
}

/// Samples to consume into this frame's new columns. Pure (no GPU), so the control law is testable.
/// Smoothed arrival rate (`avg_arrival`) nudged by a gentle proportional term toward holding the
/// reservoir at `target`, clamped ≥ 0 and ≤ `available`. It absorbs clock drift into the per-pixel
/// sample count instead of the motion — slew, never step — so the scroll stays a uniform integer
/// pixel step per frame.
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
        assert_eq!(choose_px_per_frame(1200, 5.0, 120.0), 2);
        assert_eq!(choose_px_per_frame(1200, 5.0, 60.0), 4);
        assert_eq!(choose_px_per_frame(50, 5.0, 120.0), 1);
    }

    #[test]
    fn consume_equals_arrival_at_the_target() {
        assert!((consume_samples(366.0, 1000.0, 1000.0, 0.02, 5000.0) - 366.0).abs() < 1e-9);
    }

    #[test]
    fn consume_speeds_up_when_audio_runs_ahead() {
        let c = consume_samples(366.0, 1500.0, 1000.0, 0.02, 5000.0);
        assert!((c - (366.0 + 0.02 * 500.0)).abs() < 1e-9, "got {c}");
        assert!(c > 366.0 && c < 366.0 + 50.0);
    }

    #[test]
    fn consume_eases_off_when_reservoir_is_low() {
        let c = consume_samples(366.0, 600.0, 1000.0, 0.02, 5000.0);
        assert!((c - (366.0 + 0.02 * -400.0)).abs() < 1e-9, "got {c}");
    }

    #[test]
    fn consume_never_exceeds_available_or_goes_negative() {
        assert_eq!(consume_samples(366.0, 1000.0, 1000.0, 0.02, 100.0), 100.0);
        assert_eq!(consume_samples(10.0, 0.0, 5000.0, 0.02, 5000.0), 0.0);
    }
}
