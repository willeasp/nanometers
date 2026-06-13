#ifndef NANO_DSP_H
#define NANO_DSP_H
/* C-ABI for nano-dsp's iOS facade (ADR 0008 / 0009). Mirrors crates/nano-dsp/src/ffi.rs — keep in
 * sync; crates/nano-dsp/tests/ffi_abi.rs pins the Rust side. */
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* One analyzed bin: normalized peak height (0..1) + continuous band color (ADR 0001). */
typedef struct NanoBin {
    float peak;
    float r;
    float g;
    float b;
} NanoBin;

/* One analyzed stereo bin: per-channel min/max envelope (normalized -1..1) + band color. Feeds the
 * close-up scope's filled min/max contour (L top half, R bottom half). */
typedef struct NanoStereoBin {
    float l_min;
    float l_max;
    float r_min;
    float r_max;
    float r;
    float g;
    float b;
} NanoStereoBin;

/* Opaque streaming loudness meter handle. */
typedef struct NanoMeter NanoMeter;

/* Analyze `len` mono samples into `n_bins` (peak, color) bins; `out` holds `n_bins` NanoBin.
 * Peaks are normalized to the track's global max. Returns 0 on success, -1 on bad arguments. */
int32_t nano_dsp_analyze(const float *pcm, size_t len, float sample_rate, size_t n_bins, NanoBin *out);

/* Analyze stereo `l`/`r` (`len` samples each) into `n_bins` per-channel min/max + color bins; `out`
 * holds `n_bins` NanoStereoBin. Min/max normalized to the track's global max. 0 ok, -1 on bad args. */
int32_t nano_dsp_analyze_stereo(const float *l, const float *r, size_t len, float sample_rate, size_t n_bins, NanoStereoBin *out);

/* Integrated BS.1770 LUFS over stereo `l`/`r` (`len` samples each). Returns -inf on bad arguments. */
double nano_dsp_integrated_lufs(const float *l, const float *r, size_t len, double sample_rate);

/* Streaming loudness meter: create, feed interleaved stereo, read ~10 Hz (momentary 400 ms or
 * short-term 3 s), free. */
NanoMeter *nano_meter_new(double sample_rate);
void nano_meter_push(NanoMeter *meter, const float *interleaved, size_t frames);
double nano_meter_momentary(const NanoMeter *meter);
double nano_meter_short_term(const NanoMeter *meter);
void nano_meter_free(NanoMeter *meter);

#ifdef __cplusplus
}
#endif

#endif /* NANO_DSP_H */
