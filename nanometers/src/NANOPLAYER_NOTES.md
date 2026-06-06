# nanoplayer — prototype notes

**Status:** throwaway prototype (branch `nanoplayer`). Delete or absorb when it's answered its question.

## The question

Can nanometers' renderer live in the **terminal** — a scrolling, spectrally-colored waveform plus
LUFS bars and cover art, like a real mp3 player — by **reusing the plugin's DSP core** instead of
wgpu? And is the audio→data seam clean enough that a non-GPU frontend is just "drain a ring → draw
cells"?

If yes, this is the seed of a shared-DSP crate that the monorepo idea rests on: multiple frontends
(wgpu plugin, terminal player, …) over one set of pure meter/scope/color modules.

That carve is designed in [ADR 0009](../../docs/adr/0009-workspace-crate-split-cross-platform.md):
this binary becomes `apps/nano-tui`, and the **Reused vs. throwaway** table below is the migration
map — "reused unchanged" sinks to `nano-dsp`, the `dev.rs`-forked decode/playback to `nano-audio`,
the rest to the `apps/nano-tui` shell.

## What it does

- Decodes a file (symphonia: mp3/flac/wav/aac), plays it to the default output device (cpal),
  mirroring every played sample into an `rtrb` ring — the **same seam** the plugin uses between its
  audio thread and GUI thread.
- A crossterm TUI drains that ring each frame and renders:
  - **Spectrally-colored braille waveform** — each column colored by its band energy via the
    plugin's `band_color` (low→red, mid→green, high→blue), truecolor with a 256-color fallback.
    Adapts to the terminal background: detected via OSC 11 (→ macOS appearance → `NANO_THEME`
    override), and darkened toward black on a light bg so it stays visible (`t` toggles manually).
  - **LUFS bars** (M / S / I) from `LoudnessDsp`, plus decaying L/R peak meters.
  - **Metadata** header — title / artist / album / year / track #, from ID3 + container tags.
  - **Cover art** — embedded JPEG/PNG decoded and drawn as truecolor upper-half-blocks (2 px/cell).
- **Transport**: seek ←/→ (±5s, Shift ±30s), next/prev track (n/p or ↑/↓), auto-advance at end,
  reveal-in-Finder (f).
- **Playlist**: built from the sibling audio files in the starting file's folder, natural-sorted.
- `--probe <file>`: headless decode + metadata dump (no TUI/audio) — a sanity check for the
  symphonia integration.

## Run

```sh
cargo run --features nanoplayer --bin nanoplayer -- "/path/to/song.mp3"
# or: NANO_DEV_FILE=... cargo run --features nanoplayer --bin nanoplayer
# headless check: cargo run --features nanoplayer --bin nanoplayer -- --probe "/path/to/song.mp3"
```

`[space]` play/pause · `[←/→]` seek · `[n/p]`/`[↑/↓]` track · `[f]` reveal in Finder · `[t]` toggle
light/dark palette · `[q]` quit. Resize freely. `NANO_THEME=light|dark` forces the palette.

## Reused vs. throwaway

| Piece | Verdict |
|---|---|
| `LoudnessDsp` (lib) | **Reused unchanged** — LUFS M/S/I. |
| `Filterbank` + `band_color` (lib) | **Reused unchanged** — spectral waveform coloring, plugin parity. |
| `WaveScope` (this file) | New, pure, no I/O — could be lifted into a shared viz crate. |
| cpal engine + symphonia decode | Throwaway shell (dup'd from `dev.rs`); a shared crate would unify these. |
| crossterm TUI + cover half-blocks | Throwaway shell. |

Three verbatim reuses of plugin DSP across a second, non-GPU frontend = the monorepo thesis, proven.

## Verified headless

- Metadata + cover decode on real mp3s (`--probe`): titles/artists/albums/dates correct, 640×640
  covers decoded.
- Unit tests: natural sort, 256-color cube, cover aspect/letterbox geometry, `cols==0` no-panic.
- Adversarial multi-agent review (3 lenses, each finding verified) → fixed: `cols==0` render panic,
  seek-while-paused clock freeze, narrow-terminal cover fallback, full-height scroll jitter.

## Verdict (fill in after driving it)

- Waveform color + scroll: reads right? matches the plugin's vibe?
- Cover art fidelity at half-block resolution — recognizable / cool, or too coarse?
- Do M/S/I track vs. the plugin / a reference meter?
- Seek/track-change feel snappy? any audible clicks on transitions?
- → Decision: absorb the shared-DSP split (and unify decode+playback out of `dev.rs`) into the real
  tree, or delete?

_(left blank on purpose — the answer is the only thing worth keeping from a prototype.)_
