//! Exercises the C-ABI facade through the same calls Swift will make. Gated on the `ffi` feature
//! (run with `cargo test -p nano-dsp --features ffi`).
#![cfg(feature = "ffi")]

use nano_dsp::ffi::{
    nano_dsp_analyze, nano_dsp_analyze_stereo, nano_dsp_integrated_lufs, nano_meter_free,
    nano_meter_momentary, nano_meter_new, nano_meter_push, nano_meter_short_term, NanoBin,
    NanoStereoBin,
};

fn tone(sr: f32, secs: f32) -> Vec<f32> {
    let n = (sr * secs) as usize;
    (0..n)
        .map(|i| 0.5 * (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / sr).sin())
        .collect()
}

#[test]
fn analyze_fills_normalized_bins() {
    const SR: f32 = 48_000.0;
    let pcm = tone(SR, 2.0);
    let n_bins = 150usize;
    let mut out = vec![NanoBin { peak: -1.0, r: -1.0, g: -1.0, b: -1.0 }; n_bins];
    let rc = unsafe { nano_dsp_analyze(pcm.as_ptr(), pcm.len(), SR, n_bins, out.as_mut_ptr()) };
    assert_eq!(rc, 0, "analyze should succeed");
    // Peaks normalized into 0..=1, colors in gamut, and a steady tone has a non-trivial peak.
    assert!(out.iter().all(|b| (0.0..=1.0).contains(&b.peak)), "peaks normalized");
    assert!(out.iter().all(|b| (0.0..=1.0).contains(&b.r)
        && (0.0..=1.0).contains(&b.g)
        && (0.0..=1.0).contains(&b.b)), "colors in gamut");
    assert!(out.iter().any(|b| b.peak > 0.5), "the loud tone should peak near full scale somewhere");
}

#[test]
fn analyze_rejects_null_and_zero_args() {
    let mut out = vec![NanoBin { peak: 0.0, r: 0.0, g: 0.0, b: 0.0 }; 4];
    assert_eq!(unsafe { nano_dsp_analyze(std::ptr::null(), 0, 48_000.0, 4, out.as_mut_ptr()) }, -1);
}

#[test]
fn analyze_stereo_fills_normalized_envelopes() {
    const SR: f32 = 48_000.0;
    let l = tone(SR, 2.0);
    let r = tone(SR, 2.0); // L = R
    let n_bins = 200usize;
    let mut out =
        vec![NanoStereoBin { l_min: 9.0, l_max: 9.0, r_min: 9.0, r_max: 9.0, r: -1.0, g: -1.0, b: -1.0 }; n_bins];
    let rc =
        unsafe { nano_dsp_analyze_stereo(l.as_ptr(), r.as_ptr(), l.len(), SR, n_bins, out.as_mut_ptr()) };
    assert_eq!(rc, 0, "stereo analyze should succeed");
    // Envelopes normalized into -1..=1; colors in gamut.
    assert!(
        out.iter().all(|b| (-1.0..=1.0).contains(&b.l_min)
            && (-1.0..=1.0).contains(&b.l_max)
            && (-1.0..=1.0).contains(&b.r_min)
            && (-1.0..=1.0).contains(&b.r_max)),
        "envelopes normalized to -1..1"
    );
    assert!(
        out.iter().all(|b| (0.0..=1.0).contains(&b.r) && (0.0..=1.0).contains(&b.g) && (0.0..=1.0).contains(&b.b)),
        "colors in gamut"
    );
    // A loud tone: positive max and negative min somewhere; L == R for identical channels.
    assert!(out.iter().any(|b| b.l_max > 0.5), "loud tone peaks near full scale");
    assert!(out.iter().any(|b| b.l_min < -0.5), "loud tone has negative excursion");
    assert!(out.iter().all(|b| (b.l_max - b.r_max).abs() < 1e-6 && (b.l_min - b.r_min).abs() < 1e-6),
        "L and R identical for L = R input");
}

#[test]
fn analyze_stereo_survives_non_finite_input() {
    const SR: f32 = 48_000.0;
    let mut l = tone(SR, 1.0);
    let mut r = tone(SR, 1.0);
    l[100] = f32::NAN;
    r[200] = f32::INFINITY;
    l[300] = f32::NEG_INFINITY;
    let n_bins = 100usize;
    let mut out =
        vec![NanoStereoBin { l_min: 9.0, l_max: 9.0, r_min: 9.0, r_max: 9.0, r: -1.0, g: -1.0, b: -1.0 }; n_bins];
    let rc =
        unsafe { nano_dsp_analyze_stereo(l.as_ptr(), r.as_ptr(), l.len(), SR, n_bins, out.as_mut_ptr()) };
    assert_eq!(rc, 0, "non-finite input must be sanitized, not rejected or panicked");
    assert!(
        out.iter().all(|b| b.l_min.is_finite() && b.l_max.is_finite() && b.r_min.is_finite()
            && b.r_max.is_finite() && b.r.is_finite() && b.g.is_finite() && b.b.is_finite()),
        "all fields finite"
    );
}

#[test]
fn analyze_stereo_rejects_null_and_zero_args() {
    let mut out = vec![NanoStereoBin { l_min: 0.0, l_max: 0.0, r_min: 0.0, r_max: 0.0, r: 0.0, g: 0.0, b: 0.0 }; 4];
    assert_eq!(
        unsafe { nano_dsp_analyze_stereo(std::ptr::null(), std::ptr::null(), 0, 48_000.0, 4, out.as_mut_ptr()) },
        -1
    );
}

#[test]
fn integrated_lufs_lands_in_a_plausible_band() {
    const SR: f64 = 48_000.0;
    let mono = tone(SR as f32, 4.0);
    let lufs = unsafe { nano_dsp_integrated_lufs(mono.as_ptr(), mono.as_ptr(), mono.len(), SR) };
    assert!(lufs > -30.0 && lufs < 0.0, "integrated LUFS plausible for a -6 dBFS tone: {lufs}");
}

#[test]
fn streaming_meter_roundtrips() {
    const SR: f64 = 48_000.0;
    let mono = tone(SR as f32, 4.0);
    // Interleave the mono tone as stereo L = R.
    let interleaved: Vec<f32> = mono.iter().flat_map(|&s| [s, s]).collect();
    let m = nano_meter_new(SR);
    assert!(!m.is_null());
    unsafe { nano_meter_push(m, interleaved.as_ptr(), mono.len()) };
    let s = unsafe { nano_meter_short_term(m) };
    assert!(s > -30.0 && s < 0.0, "short-term LUFS plausible: {s}");
    let mo = unsafe { nano_meter_momentary(m) };
    assert!(mo > -30.0 && mo < 0.0, "momentary LUFS plausible: {mo}");
    unsafe { nano_meter_free(m) };
}

#[test]
fn analyze_survives_non_finite_input() {
    const SR: f32 = 48_000.0;
    // A tone with NaN/inf spikes sprinkled in — must NOT panic across the boundary.
    let mut pcm = tone(SR, 1.0);
    pcm[100] = f32::NAN;
    pcm[200] = f32::INFINITY;
    pcm[300] = f32::NEG_INFINITY;
    let n_bins = 64usize;
    let mut out = vec![NanoBin { peak: -1.0, r: -1.0, g: -1.0, b: -1.0 }; n_bins];
    let rc = unsafe { nano_dsp_analyze(pcm.as_ptr(), pcm.len(), SR, n_bins, out.as_mut_ptr()) };
    assert_eq!(rc, 0, "non-finite input must be sanitized, not rejected or panicked");
    assert!(out.iter().all(|b| b.peak.is_finite() && (0.0..=1.0).contains(&b.peak)), "peaks finite & normalized");
    assert!(out.iter().all(|b| b.r.is_finite() && b.g.is_finite() && b.b.is_finite()), "colors finite");
}
