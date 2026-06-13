//! C-ABI facade over nano-dsp for the iOS app (ADR 0008 / 0009). Behind the `ffi` feature and built
//! as a `staticlib`; `cbindgen` generates the matching C header from these signatures. Three things
//! cross the boundary — offline analysis, integrated loudness, and a streaming short-term meter —
//! everything else in the app is pure Swift.

use crate::loudness::{Channels, LoudnessDsp};
use crate::waveform::color::band_color;
use crate::waveform::store::{WaveStore, BIN_SECONDS};

/// 3-band filterbank crossovers — must match the plugin/TUI (ADR 0001).
const BAND_LOW_HZ: f32 = 250.0;
const BAND_HIGH_HZ: f32 = 4000.0;

/// Replace non-finite samples (NaN / ±inf) with 0.0 at the FFI boundary. Untrusted callers (a
/// decoded/corrupt iOS buffer) can pass them, and a NaN would panic inside `band_color`'s sort —
/// and a panic across `extern "C"` is undefined behavior.
#[inline]
fn san(x: f32) -> f32 {
    if x.is_finite() { x } else { 0.0 }
}

/// One analyzed bin: normalized peak height (0..1) + continuous band color (ADR 0001). Feeds both
/// the overview scrubber and the close-up strip on iOS.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NanoBin {
    pub peak: f32,
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

/// Analyze a whole (mono) track into `n_bins` `(peak, color)` bins. `pcm` points at `len` mono
/// samples; `out` must point at room for `n_bins` `NanoBin`. Peaks are normalized to the track's
/// global max. Returns 0 on success, -1 on a null/zero-argument error.
///
/// # Safety
/// `pcm` must be valid for `len` reads and `out` valid for `n_bins` writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_dsp_analyze(
    pcm: *const f32,
    len: usize,
    sample_rate: f32,
    n_bins: usize,
    out: *mut NanoBin,
) -> i32 {
    if pcm.is_null() || out.is_null() || len == 0 || n_bins == 0 || sample_rate <= 0.0 {
        return -1;
    }
    let samples = unsafe { std::slice::from_raw_parts(pcm, len) };
    let out_slice = unsafe { std::slice::from_raw_parts_mut(out, n_bins) };

    // Size the ring to hold every closed bin for the whole track (offline, one-shot).
    let spb = (sample_rate * BIN_SECONDS).round().max(1.0) as usize;
    let total_bins = (len / spb).saturating_add(1);
    let mut store = WaveStore::new(total_bins.max(n_bins), BAND_LOW_HZ, BAND_HIGH_HZ);
    store.set_sample_rate(sample_rate);
    for &s in samples {
        let s = san(s); // guard against NaN/inf — panic across extern "C" is UB
        store.push(s, s); // mono mixdown: L = R (display only)
    }

    let closed = store.closed_samples();
    if closed == 0 {
        // Track shorter than one base bin → all silence. Use the same dim tint that the normal
        // path produces for silence so the two code paths are visually consistent.
        let c = band_color([0.0; 3]);
        for b in out_slice.iter_mut() {
            *b = NanoBin { peak: 0.0, r: c[0], g: c[1], b: c[2] };
        }
        return 0;
    }

    let spc = closed as f64 / n_bins as f64;
    let cols = store.build_columns(n_bins, spc, n_bins as i64 - 1);

    // First pass: raw peak per column (max abs across both channels) + color + global max.
    let mut peaks = Vec::with_capacity(n_bins);
    let mut colors = Vec::with_capacity(n_bins);
    let mut global = 0.0f32;
    for col in &cols {
        let p = col.env[0]
            .max
            .max(col.env[1].max)
            .max(-col.env[0].min)
            .max(-col.env[1].min)
            .max(0.0);
        global = global.max(p);
        peaks.push(p);
        colors.push(band_color(col.band_ms));
    }
    let inv = if global > 0.0 { 1.0 / global } else { 0.0 };

    for (i, b) in out_slice.iter_mut().enumerate() {
        let c = colors[i];
        *b = NanoBin { peak: (peaks[i] * inv).clamp(0.0, 1.0), r: c[0], g: c[1], b: c[2] };
    }
    0
}

/// One analyzed stereo bin: per-channel min/max envelope (normalized to −1..1 by the track's global
/// max) + continuous band color (ADR 0001). Feeds the close-up scope's filled min/max contour
/// (L top half, R bottom half) — the plugin Waveform look.
#[repr(C)]
#[derive(Clone, Copy)]
pub struct NanoStereoBin {
    pub l_min: f32,
    pub l_max: f32,
    pub r_min: f32,
    pub r_max: f32,
    pub r: f32,
    pub g: f32,
    pub b: f32,
}

/// Analyze a whole stereo track into `n_bins` per-channel `(min, max)` + color bins. `l`/`r` each
/// point at `len` samples; `out` must point at room for `n_bins` `NanoStereoBin`. Min/max are
/// normalized to the track's global max (max |sample| across both channels), so the contour fills.
/// Returns 0 on success, -1 on a null/zero-argument error.
///
/// # Safety
/// `l` and `r` must each be valid for `len` reads; `out` valid for `n_bins` writes.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_dsp_analyze_stereo(
    l: *const f32,
    r: *const f32,
    len: usize,
    sample_rate: f32,
    n_bins: usize,
    out: *mut NanoStereoBin,
) -> i32 {
    if l.is_null() || r.is_null() || out.is_null() || len == 0 || n_bins == 0 || sample_rate <= 0.0 {
        return -1;
    }
    let ls = unsafe { std::slice::from_raw_parts(l, len) };
    let rs = unsafe { std::slice::from_raw_parts(r, len) };
    let out_slice = unsafe { std::slice::from_raw_parts_mut(out, n_bins) };

    // Size the ring to hold every closed bin for the whole track (offline, one-shot).
    let spb = (sample_rate * BIN_SECONDS).round().max(1.0) as usize;
    let total_bins = (len / spb).saturating_add(1);
    let mut store = WaveStore::new(total_bins.max(n_bins), BAND_LOW_HZ, BAND_HIGH_HZ);
    store.set_sample_rate(sample_rate);
    for i in 0..len {
        store.push(san(ls[i]), san(rs[i])); // guard NaN/inf — panic across extern "C" is UB
    }

    let closed = store.closed_samples();
    if closed == 0 {
        // All silence — flat contour, the same dim tint the normal path uses for silence.
        let c = band_color([0.0; 3]);
        for b in out_slice.iter_mut() {
            *b = NanoStereoBin {
                l_min: 0.0, l_max: 0.0, r_min: 0.0, r_max: 0.0, r: c[0], g: c[1], b: c[2],
            };
        }
        return 0;
    }

    let spc = closed as f64 / n_bins as f64;
    let cols = store.build_columns(n_bins, spc, n_bins as i64 - 1);

    // Global max abs across both channels → normalize so the loudest excursion maps to ±1.
    let mut global = 0.0f32;
    for col in &cols {
        let p = col.env[0]
            .max
            .max(col.env[1].max)
            .max(-col.env[0].min)
            .max(-col.env[1].min)
            .max(0.0);
        global = global.max(p);
    }
    let inv = if global > 0.0 { 1.0 / global } else { 0.0 };
    // Empty columns merge to SILENCE (min/max 0); guard any non-finite just in case.
    let norm = |v: f32| -> f32 { if v.is_finite() { (v * inv).clamp(-1.0, 1.0) } else { 0.0 } };

    for (i, b) in out_slice.iter_mut().enumerate() {
        let col = &cols[i];
        let c = band_color(col.band_ms);
        *b = NanoStereoBin {
            l_min: norm(col.env[0].min),
            l_max: norm(col.env[0].max),
            r_min: norm(col.env[1].min),
            r_max: norm(col.env[1].max),
            r: c[0],
            g: c[1],
            b: c[2],
        };
    }
    0
}

/// Integrated (gated) BS.1770 loudness over a stereo track. `l`/`r` each point at `len` samples.
/// Returns the LUFS value, or `f64::NEG_INFINITY` on a null/zero-argument error.
///
/// # Safety
/// `l` and `r` must each be valid for `len` reads.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_dsp_integrated_lufs(
    l: *const f32,
    r: *const f32,
    len: usize,
    sample_rate: f64,
) -> f64 {
    if l.is_null() || r.is_null() || len == 0 || sample_rate <= 0.0 {
        return f64::NEG_INFINITY;
    }
    let ls = unsafe { std::slice::from_raw_parts(l, len) };
    let rs = unsafe { std::slice::from_raw_parts(r, len) };
    let mut dsp = LoudnessDsp::new(sample_rate, Channels::Stereo);
    for i in 0..len {
        dsp.push_frame(san(ls[i]), san(rs[i]));
    }
    dsp.integrated_lufs()
}

/// Opaque streaming loudness meter. Create with `nano_meter_new`, feed interleaved stereo with
/// `nano_meter_push`, read `nano_meter_momentary` (400 ms) or `nano_meter_short_term` (3 s) (~10 Hz
/// from a tap), `nano_meter_free` when done.
pub struct NanoMeter {
    dsp: LoudnessDsp,
}

/// Allocate a meter for `sample_rate`. Returns null on an invalid rate. Free with `nano_meter_free`.
#[unsafe(no_mangle)]
pub extern "C" fn nano_meter_new(sample_rate: f64) -> *mut NanoMeter {
    if sample_rate <= 0.0 {
        return std::ptr::null_mut();
    }
    Box::into_raw(Box::new(NanoMeter {
        dsp: LoudnessDsp::new(sample_rate, Channels::Stereo),
    }))
}

/// Feed `frames` interleaved L/R stereo frames (so `interleaved` has `2 * frames` floats).
///
/// # Safety
/// `meter` must be a live handle from `nano_meter_new`; `interleaved` valid for `2 * frames` reads.
/// The handle must not be accessed concurrently from multiple threads — callers must externally
/// synchronize `nano_meter_push` against any concurrent reader (`nano_meter_short_term`). (A future
/// revision may move to interior atomics if lock-free cross-thread access is needed.)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_meter_push(
    meter: *mut NanoMeter,
    interleaved: *const f32,
    frames: usize,
) {
    if meter.is_null() || interleaved.is_null() || frames == 0 {
        return;
    }
    let m = unsafe { &mut *meter };
    let buf = unsafe { std::slice::from_raw_parts(interleaved, frames.saturating_mul(2)) };
    for f in 0..frames {
        m.dsp.push_frame(san(buf[2 * f]), san(buf[2 * f + 1]));
    }
}

/// Current short-term (3 s) LUFS. Returns `f64::NEG_INFINITY` on a null handle.
///
/// # Safety
/// `meter` must be a live handle from `nano_meter_new`.
/// The handle must not be accessed concurrently from multiple threads — callers must externally
/// synchronize `nano_meter_push` against any concurrent reader (`nano_meter_short_term`). (A future
/// revision may move to interior atomics if lock-free cross-thread access is needed.)
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_meter_short_term(meter: *const NanoMeter) -> f64 {
    if meter.is_null() {
        return f64::NEG_INFINITY;
    }
    unsafe { (*meter).dsp.short_term_lufs() }
}

/// Current momentary (400 ms) LUFS — faster / more reactive than short-term. `f64::NEG_INFINITY` on null.
///
/// # Safety
/// `meter` must be a live handle from `nano_meter_new`.
/// The handle must not be accessed concurrently from multiple threads — callers must externally
/// synchronize `nano_meter_push` against any concurrent reader.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_meter_momentary(meter: *const NanoMeter) -> f64 {
    if meter.is_null() {
        return f64::NEG_INFINITY;
    }
    unsafe { (*meter).dsp.momentary_lufs() }
}

/// Free a meter handle. Null is a no-op.
///
/// # Safety
/// `meter` must be a handle from `nano_meter_new` not already freed.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn nano_meter_free(meter: *mut NanoMeter) {
    if !meter.is_null() {
        drop(unsafe { Box::from_raw(meter) });
    }
}
