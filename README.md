# nanometers

Chill open-source audio meter plugin — a single window of rearrangeable, resizable visualization **Modules** (waveform, spectrum, stereo, loudness) in a MiniMeters-inspired aesthetic. Built in Rust.

Targets Logic Pro (AU via [clap-wrapper](https://github.com/free-audio/clap-wrapper)), FL Studio, Ableton, REAPER, and Bitwig (CLAP).

## Architecture

The window is a flat horizontal strip of rearrangeable, resizable **Modules**, each owning its own DSP state, configuration, and viewport. The audio thread does almost nothing but push raw samples across a lock-free SPSC ring; every Module computes what it displays on the GUI thread.

The design is documented, and is the source of truth alongside the code:

- [`CONTEXT.md`](CONTEXT.md) — the shared glossary; every term below is defined there.
- [`docs/adr/`](docs/adr/) — architecture decision records (the *why*).
- [`docs/specs/`](docs/specs/) — per-Module build specs.

## Modules

The Module types nanometers is built around (see `CONTEXT.md` for precise definitions):

- **Oscilloscope** — the instantaneous stereo wave *shape* over a short real-time window.
- **Waveform** — the amplitude *envelope* over a broad window, spectrally colored by frequency content (3-band RGB à la Traktor/Serato: bass = red, mids = green, air = blue, broadband → white), drawn as a min/max contour.
- **Loudness** — LUFS metering per ITU-R BS.1770 / EBU R128: Momentary (400 ms), Short-term (3 s), and gated Integrated. The K-weighting and gating are hand-rolled — the shipped plugin carries no runtime loudness dependency — and checked against the reference [`ebur128`](https://crates.io/crates/ebur128) implementation in the test suite.
- **Stereometer** — the stereo field: phase/correlation and L/R balance (Lissajous / goniometer).
- **Spectrum Analyzer** — FFT magnitude across a log-frequency axis.
- **Spectrogram** — frequency-over-time heatmap.
- **VU** — classic averaged, needle-style level.

## Building (macOS)

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

Standalone build with cpal-backed audio I/O — opens the same wgpu window without a DAW.

To watch the meters react to a real song without a DAW or loopback device:

```sh
NANO_DEV_FILE="/path/to/song.mp3" cargo run --features dev-player --bin nanometers -- --backend dummy
```

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

Open source, MIT, developed by a single maintainer. If you want to play with it, build it, run it, fork it — go for it. Issues and PRs welcome but expect things to break.

## License

MIT.
