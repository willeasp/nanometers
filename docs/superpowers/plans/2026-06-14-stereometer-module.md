# Stereometer Module Implementation Plan

> **For agentic workers:** Executed INLINE this session. The DSP is TDD; the GPU render is verified live (standalone + Logic), matching how the other Modules were built.

**Goal:** A Stereometer Module — a goniometer dot-cloud of the stereo field plus a phase-correlation meter — added to the now-complete Module host.

**Architecture:** A new `StereometerModule` (the 4th concrete Module) owns a ring of recent `[L,R]` frames and its own GPU pipeline(s); it plots the recent samples as a 45°-rotated **Lissajous line** — a continuous `LineStrip` X-Y trace (mono → vertical line), age-faded along its length (newest bright → oldest dim) with normal alpha blending (no additive glow, no glow stack — a clean 1px line), in a centered square within a flex column. A new platform-free `StereoCorrelation` in `nano-dsp` (shared with TUI/iOS, ADR 0009) computes the smoothed −1..+1 phase correlation, drawn as a bar + `wgpu_text` number. Registration is the standard 5-site Module add.

**Tech Stack:** Rust, wgpu (instanced dot quads), wgpu_text (JetBrains Mono, ADR 0005), `nano-dsp`. Crate package name `nanometers` (`cargo test -p nanometers`); DSP tests `cargo test -p nano-dsp`.

**Design decisions (locked with the user, 2026-06-14):**
- Render = **Lissajous line** (continuous `LineStrip` X-Y trace), **age-fade along its length, NO additive glow / no glow stack** (a clean 1px line), normal alpha blend, single soft color.
- 45° rotation: `xn = (R − L)/2`, `yn = (L + R)/2` → mono collapses to a vertical line, width spreads horizontally, balance tilts. A small fixed `GAIN` lifts typical (sub-full-scale) material to fill the diamond; clips the rare full-scale.
- **Flex column, centered square** (`min(w,h)`), aspect-corrected via a uniform — the strip is 1D, no layout-2D work.
- Faint **reference**: the full-scale diamond + center (M vertical / S horizontal hint).
- **Correlation meter** included: smoothed −1..+1, DSP in `nano-dsp`, bar + number.
- mono input → vertical line (falls out of the rotation; no special-case).

---

## Slice 1 — `nano-dsp::StereoCorrelation` (platform-free, TDD)

**Files:** Create `crates/nano-dsp/src/correlation.rs`; `pub mod correlation;` + re-export in `crates/nano-dsp/src/lib.rs`.

Standard correlation-meter math: leaky-integrated sums of `L·R`, `L²`, `R²`; `c = Σlr / sqrt(Σll · Σrr)`, clamped to `[−1, 1]`; `0` when a side is silent (avoid 0/0). The leak (per-sample decay) sets the ballistics (a ~300 ms-ish window). Adding a NEW type to nano-dsp is safe — it doesn't touch the loudness numerics the iOS FFI guards.

- [ ] **Step 1 (RED):** tests:
  - `in_phase_mono_is_plus_one`: feed `L==R` (a sine) → `value()` → ~`+1.0`.
  - `anti_phase_is_minus_one`: feed `L == −R` → ~`−1.0`.
  - `decorrelated_is_near_zero`: independent pseudo-random L and R (fixed seed, no `rand` — a simple LCG in the test) → `|value()|` small (< 0.2 after enough samples).
  - `silence_is_zero_not_nan`: feed zeros → `0.0`, finite.
  - `clamps_to_unit_range`: value always in `[−1, 1]`.
- [ ] **Step 2:** `cargo test -p nano-dsp correlation` → FAIL (undefined).
- [ ] **Step 3 (GREEN):**
  ```rust
  /// Smoothed phase-correlation of a stereo signal in [−1, +1] (+1 = mono/in-phase, 0 = uncorrelated,
  /// −1 = anti-phase). Leaky-integrated sums give the ballistics; `value()` is the normalized result.
  pub struct StereoCorrelation {
      ll: f64,
      rr: f64,
      lr: f64,
      decay: f64, // per-sample leak; smaller = longer window
  }
  impl StereoCorrelation {
      pub fn new(sample_rate: f64) -> Self { /* decay from a ~300 ms time constant */ }
      pub fn push(&mut self, l: f32, r: f32) { /* leak the three sums, accumulate this sample */ }
      pub fn value(&self) -> f32 {
          let denom = (self.ll * self.rr).sqrt();
          if denom <= 1e-12 { 0.0 } else { (self.lr / denom).clamp(-1.0, 1.0) as f32 }
      }
  }
  ```
- [ ] **Step 4:** run → PASS. **Step 5:** commit.

## Slice 2 — Registration (the 5 sites)

**Files:** `apps/nano-plugin/src/layout.rs`, `module/mod.rs`, `editor.rs`, `menu.rs`, new `module/stereometer.rs`.

- [ ] `layout::module_type` += `pub const STEREOMETER: &str = "stereometer";`
- [ ] `module/mod.rs` += `pub mod stereometer;`
- [ ] `editor::build_module` match += `mt::STEREOMETER => Box::new(StereometerModule::new(device, format)),` (import the type)
- [ ] `menu::MenuModel::for_context` += `MenuItem { label: "Add Stereometer".into(), action: MenuAction::Add(module_type::STEREOMETER) }`
- [ ] Create `module/stereometer.rs` with a minimal compiling `StereometerModule` stub (empty Module impl) so registration builds before the render work lands. Commit once `cargo build` + the existing apply_edit/persist tests pass with the new tag.

## Slice 3 — The Lissajous line (GPU, live-verified)

**Files:** `apps/nano-plugin/src/module/stereometer.rs`.

- [ ] **Ring + ingest:** `display: Box<[StereoFrame; POINTS]>` (POINTS ≈ 2048), `write_head`; `update` folds `ctx.new` in, feeds `StereoCorrelation`, and builds the vertex buffer: the points in oldest→newest time order, each a rotated `[xn, yn]` with `xn = (R−L)/2 * GAIN`, `yn = (L+R)/2 * GAIN`. Upload to the line vertex buffer (`linearize` the ring like the Oscilloscope does).
- [ ] **Pipeline (LineStrip):** per-vertex buffer `{ pos: [f32;2] }`; topology `LineStrip`; the vertex shader applies the `aspect` uniform (`sx = min(w,h)/w`, `sy = min(w,h)/h`, set in `prepare` from `viewport`) so it's a centered square, and computes `alpha = vertex_index / (count−1)` (oldest→newest = dim→bright) for the age-fade; **normal alpha blend** (`SrcAlpha, OneMinusSrcAlpha`), NOT additive — a single clean 1px trace, no glow stack.
- [ ] **Reference frame:** a second small draw (a `LineList` or thin quads) for the full-scale diamond outline + center M/S lines, in a dim color.
- [ ] `intrinsic_width` → `None` (flex). `on_event` → `Ignored`. `save_config`/`load_config` → empty (config deferred).
- [ ] **Verify:** `cargo build`; run the dev-player and confirm a centered trace that's a vertical line on mono and opens up on a wide mix; no crash. Commit.

## Slice 4 — The correlation meter (bar + number)

**Files:** `apps/nano-plugin/src/module/stereometer.rs`.

- [ ] Own a `StereoCorrelation` (created/reset on sample-rate change, like Loudness's DSP) + a `Brush` (shared `FONT`).
- [ ] `prepare`: queue the formatted number (e.g. `format!("{:+.2}", c)`) centered under the cloud; build the correlation bar geometry (a track + a fill from center to the value, mapped −1..+1 across a strip at the bottom of the square).
- [ ] `render`: draw the cloud, the reference, the bar quads, then `brush.draw`.
- [ ] **Verify:** dev-player — the number/bar tracks (≈+1 on mono, drops toward 0 as a stereo mix widens, negative if you invert a channel). Commit.

## Slice 5 — docs + verify + merge

- [ ] Spec: add `docs/specs/stereometer-module.md` (brief — purpose, the rotation, the correlation math, the deferred bits).
- [ ] CONTEXT.md: the Stereometer term already exists; mark it built if the glossary tracks status (it doesn't — skip). README already lists it.
- [ ] `cargo test -p nanometers` + `cargo test -p nano-dsp` green; clippy clean for both new files; `./build.sh` + `auval`; standalone + a Logic look.
- [ ] Code-review pass over the diff; address findings; user confirms the look; merge to main + push.

---

## Self-review notes
- **Shared-core safety:** `StereoCorrelation` is a NEW nano-dsp type; it doesn't touch `loudness` numerics, so no iOS FFI drift (loudness-dsp memory).
- **No additive glow:** the dot pipeline blends `SrcAlpha/OneMinusSrcAlpha` (normal), not `One` — density reads as coverage + age-fade, not brightness blow-out, per the user's call.
- **Square in a 1D strip:** flex column + `min(w,h)` centered square via the aspect uniform; no layout-2D work, matches the recon's recommendation.
