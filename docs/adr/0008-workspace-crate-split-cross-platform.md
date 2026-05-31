# The render core splits into platform-free crates so plugin, TUI, and iOS share one DSP heart

nanometers wants to grow past "a plugin" into a small family: the AU/CLAP plugin it is today, a
TUI player (in progress), and an iOS audio-player app. The point of keeping these in one repo is
*reuse* — the same loudness/envelope math and, where it makes sense, the same renderers should run
in all of them. The question is where to cut the code so that reuse is real (a new shell links the
core; it doesn't fork it) without inventing layers the code doesn't need.

The good news the code already gives us: the [0002] Module rearchitecture is built, not pending.
`Module` (update → prepare → render), `FrameContext`, `Measurements`, and `Rect` exist in
`module/mod.rs`; `RenderWindow::on_frame` is already a generic host that drains the ring and drives
`Vec<Box<dyn Module>>`; the DSP (`WaveStore`, `loudness`, band color, the scroll control law) is
GPU-free and unit-tested. The single enforced boundary [0002] named — the audio→GUI ring — is the
one true bounded-context seam here. This ADR makes that seam, and one more inside the GUI side,
into *crate* boundaries.

## The decision

**Split the `nanometers` crate into a layered workspace along the reuse lines, with platform-free
crates at the bottom and thin per-target shells on top.** Lower crates never depend on higher ones,
and the dependency a crate carries is exactly the reuse it offers:

- **`nano-dsp`** — the pure domain. No `wgpu`, no `nih_plug`, no `baseview`, no platform. It owns
  the wire/value types (`StereoFrame`, `FrameContext`, `Measurements`, `Rect`), the envelope store
  (`WaveStore`/`BaseBin` + `BIN_SECONDS`), BS.1770 loudness ([0006]), band color ([0001]), and the
  scroll control law (`consume_samples`, `choose_px_per_frame`, the reservoir). It also owns a new
  **`InputEvent`** — a platform-neutral pointer/scroll/key enum carrying only what Modules per
  [0004] consume. Shared by *all three* targets; this is the crate that justifies the monorepo.
- **`nano-render`** — the wgpu Modules. Depends on `nano-dsp` + `wgpu` + `wgpu_text`. It owns the
  `Module` trait (whose methods take `wgpu::Queue`/`Device`/`CommandEncoder`/`RenderPass`), the
  concrete Oscilloscope/Waveform/Loudness renderers, the horizontal-strip layout ([0003]), and the
  drain/fan-out host loop lifted out of `RenderWindow`. It knows nothing of `baseview` or
  `nih_plug`: it takes a `wgpu` surface and an `&[InputEvent]`. Shared by plugin + iOS (both Metal).
- **`nano-audio`** — source adapters behind a "fill this ring" port: `symphonia` file decode and
  `cpal` capture/playback, both lifted from `dev.rs`, each feature-gated. Desktop/dev today; the
  TUI's audio backend tomorrow. iOS does **not** use this crate — it brings its own CoreAudio
  adapter (`cpal` has no iOS backend).
- **`apps/nano-plugin`** — today's `nanometers`: the `nih_plug` `Plugin` (the `lib.rs` audio side)
  plus the `baseview` editor host (`editor.rs`), now a thin shell over `nano-render` + `nano-dsp`.
  It owns the `nih_plug` glue, the raw-window-handle 0.5↔0.6 plumbing, and the
  `baseview::Event → InputEvent` translation.
- **`apps/nano-tui`** and **`apps/nano-ios`** — additive. The TUI links `nano-dsp` + `nano-audio`
  and renders meters to a terminal (it deliberately does *not* link `nano-render`). The iOS app is
  a `staticlib` linking `nano-render` + `nano-dsp` + a CoreAudio FFI bridge, wrapped by an Xcode
  project drawing into a `CAMetalLayer`.

Two decouplings make the split possible; everything else is moving files:

1. **`Module::on_event` stops taking `baseview::Event`.** It takes `nano_dsp::InputEvent`. Each
   shell translates its native events (baseview, UIKit touches, crossterm) into that one enum. This
   is the keystone — without it `nano-render` cannot leave the desktop.
2. **The pure types sink to `nano-dsp`.** `StereoFrame` (today in `lib.rs`) and
   `FrameContext`/`Rect`/`Measurements` (today in `module/mod.rs`, alongside the wgpu renderers)
   move down. The `Module` trait stays in `nano-render` because its signatures name `wgpu`; its
   *data* does not. Clean rule: the trait references wgpu, the types it carries don't.

The TUI is kept as a first-class target precisely because it **can't** use `nano-render` — it forces
`nano-dsp` to be genuinely renderer-independent. If the loudness/envelope output can drive a terminal
bar *and* a Metal contour, the seam is in the right place.

## Why not the alternatives

**One crate with `cfg` features per platform.** Tempting — no workspace churn. But it collapses the
reuse boundary back into conditional compilation: every consumer pulls the whole dependency cone and
the "does the TUI accidentally link wgpu?" question becomes a `cfg` audit instead of a `Cargo.toml`
fact. Crate edges make the layering *checkable* — `nano-tui` literally cannot reach `wgpu` because it
doesn't depend on the crate that has it. That property is the whole point.

**Split by technical layer the orthodox way (one crate each for "models", "services", "io").** This
is the enterprise-DDD reflex this project rejects. Our contexts are not generic strata; they are the
two the code already enforces (acquisition vs. visualization) plus the wgpu-vs-not line inside the
GUI side. Three crates that map to *observed* seams beat seven that map to a textbook.

**Put `InputEvent` in `nano-render`, not `nano-dsp`.** It would keep `nano-dsp` slightly smaller. But
the TUI consumes input too and never links `nano-render`; the neutral event type is shared vocabulary
across all shells, which is exactly what the bottom crate is for. It rides next to `Rect` and
`FrameContext` as part of the published language.

**Wait until the iOS app exists to refactor.** The split has value the moment it lands: it makes the
plugin's own boundaries enforced rather than conventional, and it unblocks the TUI (already in
progress) immediately. Deferring it means the TUI either forks the DSP or grows a dependency on the
plugin crate — both worse than doing the carve now, while the surface is small.

## Consequences

- **Sequencing keeps the plugin green throughout.** (1) Carve `nano-dsp` (pure move; the existing
  `WaveStore`/loudness tests come with it). (2) Carve `nano-render`; swap `baseview::Event →
  InputEvent` at the trait, translate in `editor.rs`. (3) `nano-plugin` becomes a thin shell —
  `./build.sh` + `auval -v` is the regression gate. (4) Extract `nano-audio` from `dev.rs`. (5) TUI
  and iOS are then purely additive. Every step compiles; no step changes runtime behavior.
- **`InputEvent` is a new published-language type.** It must cover only what [0004]'s pointer-grab
  state machine and the Modules actually consume — not mirror `baseview::Event` wholesale. Growing it
  is a deliberate vocabulary change (update `CONTEXT.md`), not a dumping ground for raw platform
  events.
- **`CONTEXT.md` stays the ubiquitous language across crates.** The glossary already is the shared
  vocabulary; the crate split doesn't fragment it. Terms span all crates; `nano-dsp` is just where
  the types that name them live.
- **iOS-specific net-new work is bounded and known.** wgpu runs on Metal; the renderers port as-is.
  The additions are: a `UiKitWindowHandle`/`CAMetalLayer` arm alongside the existing AppKit/X11/Win32
  surface plumbing, a CoreAudio (or `AVAudioEngine`-tap) output adapter feeding the ring exactly as
  `dev.rs` does today, and a thin `extern "C"` FFI surface for Swift. None of it touches `nano-dsp`
  or `nano-render`'s logic.
- **`cpal` is desktop-only and must stay feature-gated.** `nano-audio`'s `cpal` adapter does not
  build for `aarch64-apple-ios`. The ring/`StereoFrame` port is the same on iOS; only the adapter
  behind it differs. A reader must not "unify" audio I/O across the iOS/desktop line — the port is
  the unification; the adapters are meant to differ.
- **The dev-player is reframed, not removed.** It stays a desktop convenience, but it is also the
  working proof of the iOS data flow: decode → ring → fan-out → render → audio out. Its decode/output
  halves are what `nano-audio` (desktop) and the iOS CoreAudio adapter each grow from.
- **This ADR supersedes nothing; it operationalizes [0002].** The audio→GUI seam [0002] enforces in
  one binary becomes a crate edge across several. The Module contract is unchanged except for the
  `InputEvent` signature swap, which [0004] should be updated to reference.
