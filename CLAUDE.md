# nanometers — agent guide

Chill open-source audio meter plugin (Logic, FL Studio, Ableton, REAPER, Bitwig). Waveform, spectrum, and stereo visualizations in a MiniMeters aesthetic. Built in Rust on `nih-plug` + raw `wgpu` + `baseview`, AU produced via `clap-wrapper`.

Read this file before non-trivial work — most of it is hard-won and not derivable from the code alone.

## The code is the source of truth

For how nanometers actually behaves *right now*, the code wins — over this file, the ADRs, the
specs, the README, all of it. Prose drifts; the code is what runs. Don't describe, claim, or rely on
behavior you haven't confirmed in the source (or by running it) — see *Verify before claiming done*
below. When a doc and the code disagree about current behavior, the doc is stale; fix the doc to match.

The exception is *intent*, not behavior: the ADRs, specs, and glossary are the source of truth for
decisions, contracts, and vocabulary — much of which isn't built yet. Code that contradicts an
accepted ADR is a bug to fix (or an ADR to deliberately supersede), never a license to ignore it.

## Build / install / test

```sh
./build.sh                                 # builds CLAP + AU, installs to ~/Library/Audio/Plug-Ins/
cargo run --bin nanometers                 # standalone — fastest iteration, bypasses any DAW
auval -v aufx Nano Wlsp                    # quick AU sanity check; should print AU VALIDATION SUCCEEDED
killall -9 AudioComponentRegistrar         # nudge macOS to re-register if auval can't see us
```

`build.sh` does three things in order: `cargo xtask bundle` → CMake build of `auv2/` → copy the resulting `.clap` and `.component` into `~/Library/Audio/Plug-Ins/`. Always re-test in Logic with a NEW project (see Cache traps below).

## Standalone dev-player (fastest way to watch the meter react to real audio)

```sh
NANO_DEV_FILE="/path/to/song.mp3" RUST_LOG=warn \
  cargo run --features dev-player --bin nanometers -- --backend dummy
```

The `dev-player` feature (off by default, so the shipped plugin never links `symphonia`/`cpal`) decodes the file, plays it to the default output device, and streams the same samples into the waveform ring — looping forever. Any `symphonia` format (mp3/flac/wav/aac). It runs on the `dummy` backend so nih-plug doesn't also try to grab an audio device; `src/dev.rs` owns the output stream and the ring producer outright (`samples_tx` becomes `None` in `process`). No BlackHole, no DAW. Audio goes to the system default output — if you hear nothing, check it's not routed to idle Bluetooth earbuds (the device name is logged at startup).

Plain mic input also works but is fiddlier — nih-plug's CPAL standalone won't connect an input unless asked, the laptop mic is mono, and the requested sample rate must match the device:

```sh
cargo run --bin nanometers -- --audio-layout 2 \
  --input-device "MacBook Pro-mikrofon" --sample-rate 44100 --period-size 1024
```

`--audio-layout 2` selects the mono-input layout (the second entry in `AUDIO_IO_LAYOUTS`); `--input-device ""` lists devices. Default sample rate is 48 kHz, so on a 44.1 kHz device you get a `Received 558 samples, while the configured buffer size is 512` panic unless you pass `--sample-rate 44100`.

**`assert_process_allocs` / `rt-assert`.** nih-plug's audio-thread allocation guard aborts the standalone on startup — nih-plug's *own* standalone wrapper allocates on the first guarded `process` call (both cpal and dummy backends), so it's nothing in our code. It is therefore NOT a default feature. It's re-enabled only for shipping builds via the local `rt-assert` feature, which `build.sh` passes to `cargo xtask bundle`. Don't move it back into the always-on `nih_plug` features or every `cargo run` of the standalone (and the dev-player) will abort with `Memory allocation of N bytes failed`.

## Working style

- **Push back, don't validate.** If a proposal is flawed, name the flaw. User explicitly wants this over agreeable nodding.
- **Commit often, one logical change per commit.** Lead the subject with the change, use the body for the *why*. See existing history for tone.
- **Verify before claiming done.** Run `cargo check` / `./build.sh` / `auval -v` and report the actual result. No "should work" claims.
- **Debug against data, not in your head.** When stuck, instrument first (eprintln, file logging, color diagnostics like a magenta clear-color) before theorizing. The history of the waveform fix is in the git log if you want a worked example.
- **Match the trajectory.** Chill open source, MiniMeters aesthetic, no enterprise hardening, no defensive scaffolding that the code doesn't need.
- **Tone is direct and casual** — Swedish when the user writes Swedish, match their register (profanity fine, exclamations when they're hyped, dry when they're not).

## Cache traps to know about (you WILL hit these)

**Logic's per-project plugin state.** When a plugin panics during editor probing, Logic stamps "no UI available" into that project's state. Re-loading the plugin in the same project shows as loaded but the GUI window silently doesn't open — even after the plugin is fixed and `auval` passes. **Test every fresh build in a NEW Logic project.** Spending 30 minutes hunting a "regression" that turned out to be a cached failure-state is the canonical embarrassment.

**clap-wrapper incremental Info.plist.** clap-wrapper writes the AudioComponents array into the `.component`'s `Info.plist` only at link time. CMake's incremental builds skip the relink if the bundle dir already exists, leaving the old plist behind. `build.sh` explicitly deletes `auv2/build/nanometers.component` before each link to force a clean stitch. If you change `build.sh`, do NOT remove that step.

**AU sandbox and `/tmp`.** Logic's AU host (`AUHostingServiceXPC_arrow`) is sandboxed. `/tmp` writes get redirected to a per-process scratch dir you can't readily find. For debug logging, write to `~/Library/Logs/<name>.log` — the standard sandbox profile allows that path. Also mirror to `stderr`; macOS' unified log captures it.

**Cargo + partial git checkouts.** `git checkout <sha> -- <path>` writes to both index and working tree. A later `git stash pop` only restores files that were actually in the stash. If you used partial checkout to roll back a single file, that file stays at the older version when you pop. Cargo then happily builds against the stale source while you swear at the rebuild detection. Before doubting incremental compile: `strings ~/Library/Audio/Plug-Ins/Components/nanometers.component/Contents/PlugIns/nanometers.clap/Contents/MacOS/nanometers | grep <expected-recent-string>`.

## Architecture quick-tour

Three threads, one ring:

- **Audio thread**: `Plugin::process` pushes interleaved `[L, R]` samples into an `rtrb::Producer<StereoFrame>` via wait-free `push`. Also computes a decaying peak per channel and stores it in `AtomicF32`s.
- **Main / event thread**: baseview's run loop. Handles window events (resize, input) and forwards them to Modules; `RenderWindow::on_frame` is a **no-op** (it does NOT render). It owns no GPU state.
- **Render thread**: `editor.rs::run_render_loop` owns the wgpu device/queue/surface and the `Vec<Box<dyn Module + Send>>`, and loops `drain ring → update Modules → acquire → render → present`. The blocking `get_current_texture()` (Fifo + `desired_maximum_frame_latency=2`) is the clock — it stalls until a drawable frees at vblank, so the loop self-paces to the display **independent of the host's main loop**. This is what makes the scroll smooth in every DAW including FL Studio (which starves the main run loop). See **ADR 0008** — and don't reintroduce a display-link/`on_frame`-driven render path; that was the whole problem.

The SPSC `Consumer` lives behind `Mutex<Consumer>` in `Shared` only because `rtrb::Consumer` is `!Sync`. The render thread is its sole consumer, so it's effectively uncontended — `try_lock` always succeeds. Teardown is the crash-prone seam: a per-instance `RenderControl` stops+joins the render thread in `EditorHandle::drop` BEFORE `window.close()` frees the view (the thread's `Surface` references the view's `CAMetalLayer`).

The multi-Module host (each Module owning its pipelines; the host draining one ring and fanning a `FrameContext` to each) is built — designed in [`docs/adr/`](docs/adr/) 0002–0004. Per-channel waveform draws used to hit a `queue.write_buffer`-vs-submit ordering trap (one uniform buffer overwritten between L and R draws); see `feedback_wgpu_uniform_race` if you touch that.

## Roadmap & architecture decisions

In order of authority:

- **Shared vocabulary** — [`CONTEXT.md`](CONTEXT.md). Use these terms; honor the `_Avoid_` lists.
- **Decisions + rationale** — [`docs/adr/`](docs/adr/). Read the ADRs a task touches before starting.
- **Per-Module build contracts** — [`docs/specs/`](docs/specs/).
- **Priority-ordered roadmap** — the phase plan in [`docs/superpowers/plans/2026-05-30-module-host-and-modules.md`](docs/superpowers/plans/2026-05-30-module-host-and-modules.md) (Phases A–F).

If anything in this file disagrees with those, this file is the one that's wrong — fix it here, keep
the decision there.

## File layout

Cargo workspace (ADR 0009): a platform-free domain core feeds the plugin, TUI, and iOS app.

```
nanometers/
├── crates/nano-dsp/        # platform-free domain core: loudness, waveform store/color/scroll,
│                           #   FrameContext/Measurements value types, the C FFI for iOS
├── apps/
│   ├── nano-plugin/        # the CLAP/AU plugin crate
│   │   └── src/
│   │       ├── lib.rs      #   Plugin/Params/Shared — audio-thread side
│   │       ├── editor.rs   #   Editor/RenderWindow + the render thread + WindowMsg routing
│   │       ├── layout.rs   #   horizontal-strip columns + viewport geometry + hit-testing (0003)
│   │       ├── input.rs    #   host-owned PointerGrab router — reorder/reset/hover (0004)
│   │       ├── module/     #   the Module trait + waveform / loudness / oscilloscope
│   │       └── dev.rs      #   dev-player: file decode → output + ring (feature-gated)
│   ├── nano-tui/           # terminal meter over the same core
│   └── nano-ios/           # SwiftUI app over the core via FFI (0010)
├── xtask/                  # `cargo xtask bundle ...` shim around nih_plug_xtask
├── auv2/CMakeLists.txt     # clap-wrapper invocation that emits the AU bundle
└── build.sh                # cargo bundle → cmake → install
```
