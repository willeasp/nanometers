# nanometers

Chill open-source audio meter plugin with waveform, spectrum, and stereo visualizations in a MiniMeters-inspired aesthetic. Built in Rust.

Targets Logic Pro (AU via [clap-wrapper](https://github.com/free-audio/clap-wrapper)), FL Studio, Ableton, REAPER, and Bitwig (CLAP).

## Status

Early. Currently shipping:
- Stereo waveform view (1px line strips per channel, 4096-sample window ≈ 85 ms @ 48 kHz)
- Audio→GUI streaming via a lock-free SPSC ring
- Stereo peak metering with sample-rate-independent decay (computed but not yet visualized)
- LUFS loudness — BS.1770 / EBU R128 Momentary / Short-term / gated Integrated, hand-rolled and verified against [`ebur128`](https://crates.io/crates/ebur128) to ~1×10⁻¹¹ LU (computed but not yet visualized)

Working in Logic and as a standalone binary. Not yet useful as a metering tool — visualization polish lives in the roadmap below.

## Building (macOS, for now)

Requirements: Rust 1.87+, CMake 3.21+, Xcode CLI tools. Nothing else — `clap-wrapper`, the CLAP SDK, and the AudioUnit SDK are all fetched on demand.

```sh
./build.sh
```

Produces and installs:
- `~/Library/Audio/Plug-Ins/Components/nanometers.component` — AU for Logic
- `~/Library/Audio/Plug-Ins/CLAP/nanometers.clap` — CLAP for FL Studio, Bitwig, REAPER, etc.

To iterate without leaving the terminal:

```sh
cargo run --bin nanometers
```

Standalone build with cpal-backed audio I/O — opens the same wgpu window without needing a DAW restart cycle.

## Roadmap

Curated, in rough priority order:

1. **Glow / additive bloom on the waveform.** Multi-pass blur. This is the visual-identity step that makes the meter feel alive rather than utilitarian.
2. **Spectral coloring of the waveform.** Each sample colored by its frequency content — low frequencies render warm/red, high frequencies render cool/white. Implemented via short rolling FFT windows mapped to a colormap, applied per-vertex in the same line-strip pipeline. (Similar to spectrograph color-by-frequency, but on a time-domain waveform.)
3. **Thicker lines.** Metal's `LineStrip` topology renders 1 device pixel wide — half a logical pixel on Retina. Switching to triangle-strip ribbons or a fragment-shader distance-to-line approach.
4. **Spectrum analyzer view.** FFT-based, log-frequency display, ballistics.
5. **Goniometer view** with phosphor fade-trail. XY plot of `(L+R)/√2` vs `(L−R)/√2` with render-to-texture ping-pong for the decay.
6. **RMS metering** alongside peak.

## Plugin formats

- **CLAP** — native, built directly by `nih-plug`.
- **AU (AUv2)** — wrapped from the CLAP via `clap-wrapper`, embedded inside the `.component` bundle.
- **VST3** — intentionally skipped. CLAP is supported by every modern DAW that matters; the only relevant exception is Logic, which uses AU.

## Layout

```
nanometers/
├── nanometers/             # plugin crate (Rust, the actual nanometers code)
├── xtask/                  # `cargo xtask bundle` shim
├── auv2/                   # CMake project that wraps the CLAP into an AU
├── build.sh                # cargo bundle → cmake → install in one shot
└── CLAUDE.md               # agent-readable working guide
```

## Contributing

Open source, MIT, but in active early-stage development by a single maintainer. If you want to play with it, build it, run it, fork it — go for it. Issues and PRs welcome but expect things to break.

## License

MIT.
