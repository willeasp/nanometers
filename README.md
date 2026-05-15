# nanometers

Chill open-source audio meter plugin. Waveform, spectrum, and stereo visualizations with a phosphor-trail aesthetic.

## Status

Early bootstrap. v0.0.1: plugin loads, opens a dark wgpu surface, computes stereo peak with decay on the audio thread. No visualization rendered yet.

## Prerequisites

- macOS (Apple Silicon or Intel) with Xcode installed
- Rust 1.87+ (`rust-toolchain.toml` pins 1.89.0)
- CMake 3.21+
- That's it — `clap-wrapper`, the CLAP SDK, and the AudioUnit SDK are all fetched on demand.

## Building & installing

The full path for Logic:

```sh
./build.sh
```

This:
1. Builds the CLAP via `cargo xtask bundle` → `target/bundled/nanometers.clap`
2. Builds an AUv2 `.component` via clap-wrapper that embeds the CLAP
3. Installs both to `~/Library/Audio/Plug-Ins/`

Restart Logic afterwards so it re-runs `auval`. The plugin shows up under **Audio FX → willeasp → nanometers**.

For a faster iteration loop without touching the DAW:

```sh
cargo run --bin nanometers
```

That runs the standalone build (cpal-backed audio I/O) and opens the same wgpu window — no Logic restart needed when you're iterating on visuals.

## Layout

```
nanometers/
├── nanometers/          # plugin crate (lib.rs is the entire plugin today)
├── xtask/               # bundler shim — call via `cargo xtask`
├── auv2/                # CMake project that wraps the CLAP into an AU
└── build.sh             # one-shot build + install
```

## Plugin formats

- **CLAP** — native, built by nih-plug. For FL Studio, Bitwig, REAPER, etc.
- **AU (AUv2)** — built by clap-wrapper, embeds the CLAP. For Logic Pro.
- **VST3** — intentionally skipped.

## License

MIT.
