# Modules subscribe to two audio-thread publishers; per-module reduction is online and GUI-side

nanometers is becoming a multi-Module window (Oscilloscope, Waveform, Loudness, …), each Module a
rectangle that draws itself. Every Module needs data off the audio thread, but they need *different*
data with *different* tolerances: the Oscilloscope wants raw sample shape over ~tens of ms and does
not care if a frame is dropped under GUI stall; the Waveform wants an amplitude envelope over
seconds; the Loudness Module wants Integrated LUFS, a gated accumulation over the whole stream where
a single dropped sample permanently corrupts the result. There is one `rtrb` SPSC ring today
(`Shared.samples_rx`), peak is already computed on the audio thread and published via `AtomicF32`,
and the GUI thread is the only consumer. The question was where each Module's DSP runs and how data
crosses the audio→GUI seam — the one boundary in this codebase that is *enforced* (RT-safety: no
locks, no alloc on the audio side), which makes it the only true bounded-context boundary here.

## The decision

**The audio→GUI seam carries two kinds of published data, and Modules subscribe to what they need.**

1. **Raw-signal ring** (the existing `rtrb` SPSC ring) — the literal sample stream, *lossy*
   (drop-on-starve). For shape/envelope Modules. Raw is inherently a *short-horizon* payload:
   anything longer than the Oscilloscope's window is, by nature, an envelope, not raw shape.

2. **Loss-intolerant scalars** (peak, LUFS) — computed *on the audio thread*, where every sample is
   seen, and published via atomics. Stateful/accumulating measurements (K-weighted gated LUFS) live
   here because they cannot survive frame loss.

On the GUI thread, **one consumer drains the ring once per frame** into a reused scratch slice and
fans it out as a `FrameContext { new: &[StereoFrame], meas: &Measurements }` to every Module. Each
Module **reduces online**: it folds only that frame's new samples into its own derived state and
keeps nothing it doesn't display. The Waveform stores min / max / mean-square at a **0.5 ms base bin
resolution** (derived from sample rate), merging bins down to pixel columns at draw time. Column
resolution and viewable window are chosen *inside the Module*.

This yields the `Module` trait — two phases mirroring the existing `on_frame` and the
write-buffer-before-render-pass ordering already documented in `editor.rs`:

```rust
trait Module {
    fn update(&mut self, ctx: &FrameContext, queue: &Queue);       // fold new samples → own GPU buffers
    fn render(&mut self, rpass: &mut RenderPass, viewport: Rect);  // draw into my rectangle
}
```

## Why not the alternatives

**Pre-reduce envelopes on the audio thread.** Tempting for bounded memory, but the envelope's
resolution and window are *Visualization* decisions — baking a base bin size on the audio thread
leaks a Visualization parameter across the seam and caps dynamic zoom. The numbers also don't
justify it: 6 s of stereo raw is ~2.3 MB and re-folding ~800 new samples/frame is trivial, so there
is no cost to pay for. Reduction stays GUI-side.

**Each Module drains the ring itself.** `rtrb` is single-consumer — the first Module to `pop()` a
frame eats it for the others. One drainer fanning out a slice is the only correct shape, and it
keeps the per-sample loop inside each Module (monomorphized) rather than as a virtual call per
sample.

**Compute LUFS on the GUI thread off the raw ring.** The ring is lossy by design; K-weighting is a
stateful filter and Integrated LUFS is whole-stream gated accumulation, so GUI-side computation off
a drop-on-starve buffer gives silently wrong numbers. Loss-intolerant measurements must run audio-side.

**Store Waveform columns at display resolution.** A resizable window would orphan the history on
every resize (blank, scroll back in). Base-resolution storage makes resize a cheap re-merge. 0.5 ms
also marks the floor below which "envelope" stops being meaningful and the job belongs to the
Oscilloscope — so it doubles as the domain boundary between the two Modules.

## Consequences

- **The integration contract.** This is what the Loudness agent builds against: their Module is a
  `Measurements` *producer* on the audio side plus a GUI-side renderer that reads `meas`, not a raw
  consumer. New Module types pick a publisher and implement the two-phase trait.
- **`RenderWindow` becomes the host.** Ingest + linearise must move out of it into the drain/fan-out
  loop; the current waveform draw is already ~90 % of one `Module`.
- **`Measurements` risks becoming a catalog everyone reads.** It stays small only if it carries just
  what some Module subscribed to. Watch for it growing into a god-object.
- **Per-column store is shared with [0001].** Waveform columns carry min / max / mean-square (this
  ADR) *plus* the 3 band-energy floats for spectral coloring (0001). Merging must stay associative —
  store mean-square, never RMS; average mean-squares and `sqrt` at draw.
- **Loss is asymmetric and deliberate.** Visuals tolerate dropped frames; measurements never see
  them. A reader must not "fix" the ring's drop-on-starve behavior thinking it's a bug.
