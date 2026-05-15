# nanometers — agent guide

Chill open-source audio meter plugin (Logic, FL Studio, Ableton, REAPER, Bitwig). Waveform, spectrum, and stereo visualizations in a MiniMeters aesthetic. Built in Rust on `nih-plug` + raw `wgpu` + `baseview`, AU produced via `clap-wrapper`.

Read this file before non-trivial work — most of it is hard-won and not derivable from the code alone.

## Build / install / test

```sh
./build.sh                                 # builds CLAP + AU, installs to ~/Library/Audio/Plug-Ins/
cargo run --bin nanometers                 # standalone — fastest iteration, bypasses any DAW
auval -v aufx Nano Wlsp                    # quick AU sanity check; should print AU VALIDATION SUCCEEDED
killall -9 AudioComponentRegistrar         # nudge macOS to re-register if auval can't see us
```

`build.sh` does three things in order: `cargo xtask bundle` → CMake build of `auv2/` → copy the resulting `.clap` and `.component` into `~/Library/Audio/Plug-Ins/`. Always re-test in Logic with a NEW project (see Cache traps below).

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

Two threads, one ring:

- **Audio thread**: `Plugin::process` pushes interleaved `[L, R]` samples into an `rtrb::Producer<StereoFrame>` via wait-free `push`. Also computes a decaying peak per channel and stores it in `AtomicF32`s.
- **GUI thread**: each `on_frame` drains the SPSC ring into a 4096-sample local ring (per channel), linearises it into contiguous scratch arrays, uploads to per-channel `vertex_buffer`s, and renders.

The SPSC `Consumer` lives behind `Mutex<Consumer>` in `Shared` only because `rtrb::Consumer` is `!Sync`. The audio thread NEVER touches that mutex, so it's effectively uncontended — `try_lock` always succeeds.

Per-channel `bind_group`s for the waveform renderer are deliberate: a previous version reused one uniform buffer and overwrote it between L and R draws, which doesn't work because `queue.write_buffer` is scheduled before the next submit, not interleaved with encoded commands. Both draws ended up reading the second write. Single line where two should be. See `feedback_wgpu_uniform_race` if needed.

## Roadmap (curated, in priority order)

1. **Glow / additive bloom on the waveform.** Multi-pass blur in wgpu: render the line to an offscreen RT, horizontal Gaussian, vertical Gaussian, additive composite over the background. This is the visual identity step.
2. **Spectral coloring of the waveform.** Color each sample by its dominant frequency content — low freq → red, high freq → light/white. Implement via short rolling FFT windows (or zero-crossing-rate as a cheap proxy), map spectral centroid to a colormap, color the vertices in the same pipeline. Similar to spectrograph color-by-frequency but applied to a time-domain waveform.
3. **Line thickness.** Metal's `LineStrip` is always 1 device pixel — on Retina that's 0.5 logical pixels and reads as subtle to the point of "did anything render?" Switch to triangle-strip generated quads or fragment-shader-distance-to-line.
4. **Spectrum analyzer view.** FFT (`realfft`), log-frequency display, Blackman-Harris or Hann window, 50–75% overlap, ballistics on bin magnitudes.
5. **Goniometer view** with phosphor fade-trail. Render-to-texture ping-pong: dim previous texture by α per frame, draw new XY points additively on top.
6. **RMS** alongside peak.

## File layout

```
nanometers/
├── nanometers/             # plugin crate
│   ├── src/lib.rs          # Plugin/Params/Shared — audio-thread side
│   └── src/editor.rs       # Editor/RenderWindow/WaveformRenderer — GUI-thread side
├── xtask/                  # `cargo xtask bundle ...` shim around nih_plug_xtask
├── auv2/CMakeLists.txt     # clap-wrapper invocation that emits the AU bundle
└── build.sh                # cargo bundle → cmake → install
```
