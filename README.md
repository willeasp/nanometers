# nanometers

Chill open-source audio meter plugin — a single window of rearrangeable, resizable visualization **Modules** (waveform, spectrum, stereo, loudness) in a MiniMeters-inspired aesthetic. Built in Rust.

Targets Logic Pro (AU via [clap-wrapper](https://github.com/free-audio/clap-wrapper)), FL Studio, Ableton, REAPER, and Bitwig (CLAP).

## Status

Early, and mid-rearchitecture into a **multi-Module** window — a flat strip of rearrangeable, resizable Modules (Waveform, Loudness, Spectrum Analyzer, Stereometer, …), MiniMeters-style. The architecture is designed in [`docs/adr/`](docs/adr/) over a shared glossary in [`CONTEXT.md`](CONTEXT.md); the Waveform Module is specced in [`docs/specs/waveform-module.md`](docs/specs/waveform-module.md).

Currently shipping:
- A basic real-time stereo display (conceptually an **Oscilloscope** — a 4096-sample ≈ 85 ms window)
- Audio→GUI streaming via a lock-free SPSC ring; decaying stereo peak (computed, not yet drawn)
- A dev-only file player for iterating on visuals without a DAW or loopback device

Working in Logic and as a standalone binary. Not yet useful as a metering tool — the Module buildout is the roadmap below.

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

To watch the meters react to a real song without a DAW or loopback device:

```sh
NANO_DEV_FILE="/path/to/song.mp3" cargo run --features dev-player --bin nanometers -- --backend dummy
```

## Roadmap

nanometers is becoming a single window hosting multiple **Modules** you can rearrange and resize — see [`CONTEXT.md`](CONTEXT.md) for the vocabulary and [`docs/adr/`](docs/adr/) for the architecture. Rough order:

1. **Module host + layout.** The multi-Module window: a flat horizontal strip of resizable, reorderable columns, each Module owning its own config and rendering into its own viewport. *Foundational; in progress.*
2. **Waveform Module.** Broad, scrolling amplitude view, **spectrally colored** by frequency content — 3-band RGB à la Traktor/Serato (bass = red, mids = green, air = blue, broadband → white) — drawn as a smooth min/max contour. The visual-identity step. *Specced; in progress.*
3. **Loudness Module.** Momentary / Short-term / Integrated LUFS per ITU-R BS.1770 / EBU R128. *In progress.*
4. **Stereometer Module.** Stereo field: phase/correlation and L/R balance (Lissajous / goniometer). *Next.*
5. **Spectrum Analyzer Module.** FFT-based, log-frequency display, ballistics.
6. **Spectrogram Module.** Frequency-over-time heatmap.
7. **Oscilloscope Module.** Today's real-time trace, formalized as a Module; later, pitch-following.
8. **VU Module.** Classic averaged, needle-style level.

Later polish (deliberately deferred):
- **Glow / bloom on the Waveform** — a real multi-pass blur reading off the contour outline, once the Waveform's colored identity is in. (It was over-prioritized before; color is the identity, glow is polish.)
- **RMS** alongside peak — likely folds into the Loudness Module.

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
├── CONTEXT.md              # shared glossary (the project's ubiquitous language)
├── docs/adr/               # architecture decision records
├── docs/specs/             # per-Module build specs
└── CLAUDE.md               # agent-readable working guide
```

## Contributing

Open source, MIT, but in active early-stage development by a single maintainer. If you want to play with it, build it, run it, fork it — go for it. Issues and PRs welcome but expect things to break.

## License

MIT.
