# Phase F1 — Module config persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Make the Module opaque-config persistence path (ADR 0003) actually work end-to-end — it's currently a dead-end: `Column.config` serializes through serde fine, but `save_config()`/`load_config()` are **never called anywhere**, so every module always boots at defaults and any config it had is silently dropped.

**Architecture:** Modules live on the render thread (ADR 0008), so both config hooks go render-side: `load_config` in `RenderWindow::create` right after `build_module` (synchronous, before the thread launches); `save_config` flushed back into `Column.config` + `set_layout` after each input batch in `run_render_loop` (config only changes via user input, so that's exactly when — and the only time — it can have changed). Config bytes are JSON (`serde_json`, already a dep; human-readable persisted state aids debugging).

**Scope (per the 2026-06-13 grill — F1 only):** Fix the plumbing + give the Waveform one genuinely-persisted config knob (`window_seconds`, read live in the scroll calc) as the proof + tests + doc reconcile. NO config-edit UI (that's F2), NO multi-instance (F3), NO Loudness config (its only knob — Target/LU-display — is spec-deferred, so storing it now is YAGNI; its stubs stay). Oscilloscope config is deferred too: its buffer is a compile-time-sized array (`Box<[StereoFrame; DISPLAY_BUFFER_LEN]>`), so `window_samples` can't vary without restructuring to a `Vec` — not worth it for the proof.

---

## File structure

- `apps/nano-plugin/src/module/waveform/mod.rs` — `WaveformConfig { window_seconds }` (serde) + `to_bytes`/`from_bytes`; a `window_seconds` field read in the scroll calc instead of the const; `save_config`/`load_config` route through the struct.
- `apps/nano-plugin/src/editor.rs` — `load_configs` (in `create`) + `flush_configs` (in `run_render_loop`) plumbing, both pure-ish helpers + a fake-Module unit test.
- `docs/adr/0003-layout-horizontal-strip.md`, `docs/specs/waveform-module.md` — reconcile (config is now actually persisted, not just a serde shape; `window_seconds` is config).

---

## Task F1.1: WaveformConfig struct + serde round-trip (pure TDD)

**Files:** Modify `apps/nano-plugin/src/module/waveform/mod.rs`

- [ ] **Step 1: Write the failing test** in waveform's (new) `mod tests`:

```rust
#[test]
fn waveform_config_round_trips_and_tolerates_garbage() {
    let c = WaveformConfig { window_seconds: 3.5 };
    assert_eq!(WaveformConfig::from_bytes(&c.to_bytes()), c);
    // Empty (Column::new default) and unparseable bytes → defaults, never a panic (trait contract).
    assert_eq!(WaveformConfig::from_bytes(&[]), WaveformConfig::default());
    assert_eq!(WaveformConfig::from_bytes(b"{not json"), WaveformConfig::default());
}
```

- [ ] **Step 2: Run, watch fail** (`WaveformConfig` doesn't exist).

Run: `cargo test -p nanometers --lib module::waveform`
Expected: FAIL — `cannot find type WaveformConfig`.

- [ ] **Step 3: Implement** near the top of the module (after the consts):

```rust
/// Per-instance Waveform config (ADR 0003), persisted as the column's opaque bytes. Today just the
/// visible window; band crossovers / outline / color tuning join as they become editable (F2+).
#[derive(Clone, Copy, Debug, PartialEq, serde::Serialize, serde::Deserialize)]
pub struct WaveformConfig {
    pub window_seconds: f64,
}

impl Default for WaveformConfig {
    fn default() -> Self {
        Self { window_seconds: DISPLAY_WINDOW_SECONDS }
    }
}

impl WaveformConfig {
    fn to_bytes(self) -> Vec<u8> {
        serde_json::to_vec(&self).unwrap_or_default()
    }
    /// Unrecognized / empty / corrupt bytes leave the module at its defaults (trait contract,
    /// module/mod.rs) rather than panic — a future build's richer config must not brick this one.
    fn from_bytes(bytes: &[u8]) -> Self {
        serde_json::from_slice(bytes).unwrap_or_default()
    }
}
```

(Keep `DISPLAY_WINDOW_SECONDS` as the default source so the knob's default stays single-sourced.)

- [ ] **Step 4: Run, watch pass.** `cargo test -p nanometers --lib module::waveform` → PASS.

- [ ] **Step 5: Commit.**

```
feat(waveform): WaveformConfig (window_seconds) with JSON round-trip

The first slice of real Module-owned config (ADR 0003): a serde struct persisted as the column's
opaque bytes, JSON-encoded. from_bytes tolerates empty/garbage → defaults (trait contract), so a
future build's richer config can't brick this one. Not applied or wired yet (next steps).
```

---

## Task F1.2: Waveform applies window_seconds from its config

**Files:** Modify `apps/nano-plugin/src/module/waveform/mod.rs`

- [ ] **Step 1: Add a `config: WaveformConfig` field** to `WaveformModule`; init `WaveformConfig::default()` in `new()`.

- [ ] **Step 2: Read the config, not the const, in the scroll calc.** At waveform/mod.rs:474 and :478, replace `DISPLAY_WINDOW_SECONDS` with `self.config.window_seconds`. (The const remains as the `Default`.)

- [ ] **Step 3: Implement `save_config`/`load_config`** (replace the empty stubs):

```rust
fn save_config(&self) -> Vec<u8> {
    self.config.to_bytes()
}
fn load_config(&mut self, bytes: &[u8]) {
    self.config = WaveformConfig::from_bytes(bytes);
}
```

- [ ] **Step 4: `cargo build` to confirm it compiles + links** (no unit seam — applying needs a GPU module).

Run: `cargo build -p nanometers --bin nanometers`
Expected: clean.

- [ ] **Step 5: Commit.**

```
feat(waveform): apply window_seconds from config; route save/load through it

The scroll calc reads self.config.window_seconds instead of the const, and save_config/load_config
round-trip the WaveformConfig. The const stays as the default. No UI changes it yet (F2) — this is
the apply side of the persistence path.
```

---

## Task F1.3: Generic config plumbing — load on spawn, flush after input (TDD)

**Files:** Modify `apps/nano-plugin/src/editor.rs`

The bug fix proper: call the hooks. Extract two pure-ish helpers so the logic is unit-testable with a fake Module (no GPU — the helpers only call `save_config`/`load_config`, never `render`).

- [ ] **Step 1: Write the failing test** in editor.rs `mod tests` with a no-GPU fake Module:

```rust
struct FakeModule {
    config: Vec<u8>,
}
impl Module for FakeModule {
    fn update(&mut self, _c: &FrameContext, _q: &wgpu::Queue) {}
    fn render(&mut self, _r: &mut wgpu::RenderPass, _v: Rect) {}
    fn on_event(&mut self, _e: &baseview::Event, _v: Rect) -> crate::module::EventStatus {
        crate::module::EventStatus::Ignored
    }
    fn save_config(&self) -> Vec<u8> {
        self.config.clone()
    }
    fn load_config(&mut self, bytes: &[u8]) {
        self.config = bytes.to_vec();
    }
}

#[test]
fn configs_load_into_modules_then_flush_back_into_columns() {
    let mut layout = vec![
        column_with_config(7, module_type::WAVEFORM, 0.5, b"persisted-A".to_vec()),
        column_with_config(9, module_type::LOUDNESS, 0.5, b"persisted-B".to_vec()),
    ];
    let mut modules: Vec<Box<dyn Module + Send>> = vec![
        Box::new(FakeModule { config: Vec::new() }),
        Box::new(FakeModule { config: Vec::new() }),
    ];
    // LOAD: the persisted bytes reach the modules (1:1 by position).
    load_configs(&mut modules, &layout);
    assert_eq!(modules[0].save_config(), b"persisted-A");
    assert_eq!(modules[1].save_config(), b"persisted-B");
    // A live config change, then FLUSH: the new bytes land back in the columns.
    modules[0].load_config(b"changed-A");
    flush_configs(&modules, &mut layout);
    assert_eq!(layout[0].config, b"changed-A");
    assert_eq!(layout[1].config, b"persisted-B");
}
```

- [ ] **Step 2: Run, watch fail** (`load_configs`/`flush_configs` don't exist).

Run: `cargo test -p nanometers --lib editor::tests::configs_load`
Expected: FAIL.

- [ ] **Step 3: Implement** the helpers in editor.rs (near `build_module`):

```rust
/// Push each column's persisted opaque config (ADR 0003) into its freshly-built Module. Called at
/// editor spawn AFTER build_module — modules + layout are 1:1 by position. (No-op for the default
/// empty bytes; modules treat unrecognized config as defaults, so this is always safe.)
fn load_configs(modules: &mut [Box<dyn Module + Send>], layout: &[Column]) {
    for (m, c) in modules.iter_mut().zip(layout.iter()) {
        m.load_config(&c.config);
    }
}

/// Flush each live Module's config back into its column's bytes. Called after an input batch (the
/// only time config can change), so a host-triggered persist — whenever it lands — sees fresh bytes.
fn flush_configs(modules: &[Box<dyn Module + Send>], layout: &mut [Column]) {
    for (m, c) in modules.iter().zip(layout.iter_mut()) {
        c.config = m.save_config();
    }
}
```

- [ ] **Step 4: Run, watch pass.** `cargo test -p nanometers --lib editor::tests` → PASS.

- [ ] **Step 5: Wire `load_configs` into `RenderWindow::create`** right after the `build_module` loop (and before `reconcile_fixed_widths`, which is independent):

```rust
let mut modules: Vec<Box<dyn Module + Send>> = layout
    .iter()
    .map(|c| build_module(&c.module_type, &device, surface_config.format))
    .collect();
load_configs(&mut modules, &layout); // restore persisted per-instance config (ADR 0003)
```

- [ ] **Step 6: Wire `flush_configs` into `run_render_loop`** after the input loop. Today the loop calls `state.set_layout(new)` per reorder commit inside the input loop; fold persistence into ONE post-batch publish so config rides with it:

```rust
let mut layout_dirty = false;
for ev in &inputs {
    if let Some(new) = router.handle(ev, &layout, &committed_vps, &mut modules, scale_factor) {
        layout = new;
        layout_dirty = true;
    }
}
// Persist when something durable changed: a committed reorder, or a discrete press/release/scroll
// that a module may have turned into a config change (the only way config mutates). Pure cursor-move
// batches (hover / drag-tracking) publish nothing — no per-frame lock on the idle/hover path.
let discrete = inputs.iter().any(|e| {
    matches!(
        e,
        baseview::Event::Mouse(
            baseview::MouseEvent::ButtonPressed { .. }
                | baseview::MouseEvent::ButtonReleased { .. }
                | baseview::MouseEvent::WheelScrolled { .. }
        )
    )
});
if layout_dirty || discrete {
    flush_configs(&modules, &mut layout);
    state.set_layout(layout.clone());
}
```

(Replaces the previous per-commit `state.set_layout(new.clone())`. The single post-batch publish carries both the reorder and the flushed config. F2's config-edit interactions will be press/scroll-driven, so they trigger this for free.)

- [ ] **Step 7: `cargo test -p nanometers --lib` + `cargo build`** — all green, links.

- [ ] **Step 8: Commit.**

```
fix(editor): actually call save_config/load_config — config persistence was a dead-end

ADR 0003's opaque-config path was wired through serde but never bridged to the modules:
save_config/load_config existed on every module yet had ZERO call sites, so Column.config always
round-tripped as empty and every reopen booted at defaults. load_configs restores persisted bytes
into the modules at spawn; flush_configs writes live config back after each input batch (the only
time it can change), folded into a single post-batch set_layout that also carries reorders. Tested
with a no-GPU fake Module.
```

---

## Task F1.4: Reconcile docs

**Files:** `docs/adr/0003-layout-horizontal-strip.md`, `docs/specs/waveform-module.md`

- [ ] **Step 1: ADR 0003** — the "serde shape is a contract" consequence (around line 59-60) currently reads as forward-looking; add that config is now actually persisted end-to-end (load at spawn, flush after input), and that `save_config`/`load_config` are the live bridge — not just the serde shape. Keep it tight.

- [ ] **Step 2: waveform-module.md** — mark `window_seconds` as the first persisted config field (the rest of the §6 config table remains future). Note JSON encoding of the opaque blob.

- [ ] **Step 3: Commit.**

```
docs: record that Module config now persists end-to-end (F1)

ADR 0003 + the waveform spec: save_config/load_config are now the live bridge between a module and
its persisted Column.config bytes (JSON), with window_seconds as the first real persisted knob.
```

---

## Self-review

- **Bug fixed + tested:** the dead-end (no call sites) is closed by F1.3; proven by the fake-Module test (load → change → flush) and the WaveformConfig serde round-trip. The real GUI round-trip (change window_seconds, reopen) isn't observable until F2 adds an edit interaction — F1 verifies the seam, not a user-visible change.
- **Trait contract honored:** `from_bytes` returns defaults on empty/garbage (module/mod.rs: "unrecognized blob should leave the Module at its defaults rather than panic").
- **No regressions:** the per-reorder `set_layout` is replaced by one post-batch publish carrying both reorder + config; idle frames do zero extra work (`inputs.is_empty()` guard).
- **No iOS-FFI risk:** `window_seconds` is plugin-side display state; `nano-dsp` DSP math is untouched.
- **Deferred (noted, not silently dropped):** Loudness config (spec-deferred Target/LU), Oscilloscope config (fixed-array restructuring), Waveform band/outline/color config, and the config-edit UI — all F2+.
