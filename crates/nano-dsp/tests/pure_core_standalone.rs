//! `nano-dsp` is the platform-free domain core (ADR 0008): it must be usable on its own, with no
//! `wgpu`, no `nih_plug`, no `baseview` — that property is the whole point of the crate. This test
//! drives the full pure pipeline through ONLY `nano-dsp`'s public API, so it both documents the
//! intended standalone usage and fails to compile the day someone leaks a GUI/plugin dependency
//! into the crate. It is the renderer-independence guard ADR 0008 calls for (the TUI relies on it).

use nano_dsp::loudness::{Channels, LoudnessDsp};
use nano_dsp::waveform::color::band_color;
use nano_dsp::waveform::store::{WaveStore, BIN_SECONDS};
use nano_dsp::waveform::{choose_px_per_frame, consume_samples};
use nano_dsp::{FrameContext, Measurements, Rect, StereoFrame};

/// A short, loud 1 kHz stereo tone the way the audio thread would hand it across the ring.
fn tone(sample_rate: f32, secs: f32) -> Vec<StereoFrame> {
    let n = (sample_rate * secs) as usize;
    (0..n)
        .map(|i| {
            let s = 0.5 * (2.0 * std::f32::consts::PI * 1000.0 * i as f32 / sample_rate).sin();
            [s, s]
        })
        .collect()
}

#[test]
fn pure_pipeline_runs_with_no_platform_deps() {
    const SR: f32 = 48_000.0;
    let frames = tone(SR, 1.0);

    // 1. FrameContext is the published audio→GUI language (ADR 0002): a borrowed sample slice plus
    //    host metadata. A consumer must be able to build one from plain values.
    let meas = Measurements::new();
    let ctx = FrameContext { new: &frames, meas: &meas, sample_rate: SR, mono: false };
    assert_eq!(ctx.new.len(), frames.len());
    assert!(!ctx.mono);

    // 2. Envelope store folds the stream into base bins and merges a sample range back out.
    let window_bins = (8.0 / BIN_SECONDS).round() as usize;
    let mut store = WaveStore::new(window_bins, 250.0, 4000.0);
    store.set_sample_rate(ctx.sample_rate);
    for &[l, r] in ctx.new {
        store.push(l, r);
    }
    assert!(store.closed_samples() > 0, "tone should have closed whole bins");
    let col = store.merge_sample_range(0, store.closed_samples() as i64);
    assert!(col.env[0].max > 0.3, "merged column should carry the tone's level");

    // 3. Band color maps the merged band energies to an RGB triple in range.
    let rgb = band_color(col.band_ms);
    assert!(rgb.iter().all(|c| (0.0..=1.0).contains(c)), "color in gamut: {rgb:?}");

    // 4. Scroll control law is pure arithmetic — no GPU, no clock.
    let px = choose_px_per_frame(1200, 5.0, 120.0);
    assert_eq!(px, 2);
    let consumed = consume_samples(366.0, 1000.0, 1000.0, 0.02, 5000.0);
    assert!((consumed - 366.0).abs() < 1e-9, "at target, consume == arrival");

    // 5. Loudness DSP measures the same stream and lands at a sane LUFS for a -6 dBFS tone.
    let mut loud = LoudnessDsp::new(SR as f64, Channels::Stereo);
    for &[l, r] in ctx.new {
        loud.push_frame(l, r);
    }
    let s = loud.short_term_lufs();
    assert!(s > -30.0 && s < 0.0, "short-term LUFS in a plausible band: {s}");

    // 6. Rect geometry helper is pure and platform-free.
    let r = Rect { x: 0.0, y: 0.0, w: 800.0, h: 600.0 };
    assert_eq!(r.clip_transform(800.0, 600.0), [1.0, 0.0, 1.0, 0.0]);
}
