# All metering is GUI-side off one pushed sample stream; the audio thread only pushes raw samples

nanometers is becoming a multi-Module window (Oscilloscope, Waveform, Loudness, …), each Module a
rectangle that draws itself. Every Module needs data off the audio thread. There is one `rtrb` SPSC
ring today (`Shared.samples_rx`) carrying the raw sample stream, a decaying peak already computed on
the audio thread and published via `AtomicF32`, and the GUI thread is the only consumer. The question
was where each Module's DSP runs and how data crosses the audio→GUI seam — the one boundary in this
codebase that is *enforced* (RT-safety: no locks, no alloc on the audio side), which makes it the
only true bounded-context boundary here.

## The decision

**The audio thread does almost nothing but push raw samples. Every Module — including Loudness —
computes what it needs on the GUI thread from that one stream.**

- **Raw-signal ring** (the existing `rtrb` SPSC ring) — the literal interleaved sample stream. The
  audio thread pushes; the GUI thread is the single consumer.
- **One consumer drains the ring once per frame** into a reused scratch slice and fans it out as
  `FrameContext { new: &[StereoFrame], meas: &Measurements, sample_rate, mono }` to every Module.
  `sample_rate` and `mono` are host metadata (read once from the audio thread's `initialize`-time
  values, constant per stream) the host puts on the context so Modules never reach into the audio
  side for them. Each Module **reduces online**: it folds only that frame's new samples into its own
  GUI-side state and keeps nothing it doesn't display.
- The Waveform stores min / max / mean-square **per channel** at a **0.5 ms base bin resolution**
  (derived from sample rate), merging bins down to pixel columns at draw time. The Loudness Module
  runs K-weighting + 100 ms bins + gated Integrated entirely GUI-side, keeping its own bin history.
  Column resolution, viewable window, and gating are all chosen *inside the Module*.

`Measurements` is a second, minor channel: a small set of scalars the audio thread computes because
they are cheap and broadly useful (today: the decaying peak `AtomicF32`). It is **not** where Module
measurements live — Modules derive their own from the ring. It remains as a documented escape hatch
for any future measurement that genuinely cannot tolerate the ring's drop-on-starve behavior;
**nothing currently qualifies** (see below), so it stays tiny.

This yields the `Module` trait — two phases mirroring the existing `on_frame` and the
write-buffer-before-render-pass ordering already documented in `editor.rs`:

```rust
trait Module {
    fn update(&mut self, ctx: &FrameContext, queue: &Queue);       // fold new samples → own GPU buffers
    fn render(&mut self, rpass: &mut RenderPass, viewport: Rect);  // draw into my rectangle
}
```

## Why not the alternatives

**Compute loss-intolerant measurements (LUFS) on the audio thread and publish via atomics.** This was
the original draft of this ADR; it was reversed. The case *for* it: the ring is drop-on-starve,
K-weighting is a stateful filter, and Integrated LUFS is a whole-stream gated accumulation that never
self-heals, so a dropped sample permanently skews it. The case *against*, which won:

- The ring only drops if the GUI thread stalls for longer than the ring's depth (hundreds of ms,
  tunable). That is a hung window — a visible failure the user notices and fixes, not a silent
  background error.
- The resulting error, in that already-pathological case, is hundredths of a dB, and only on
  Integrated (Momentary / Short-term self-heal within their own windows).
- Defending against it costs a whole second data path: per-instance audio-side producers (which
  collide with [0003]'s runtime multi-instance on a no-alloc thread), a GUI→audio control path just
  for Loudness reset, and an ever-growing `Measurements` catalog. That is exactly the "defensive
  scaffolding the code doesn't need" this project rejects.

So loudness is a normal GUI-side Module like every other meter. The audio-side `Measurements` path
stays documented as an escape hatch but is currently unused beyond the legacy peak — and even that
could move GUI-side later for full uniformity.

**Pre-reduce envelopes on the audio thread.** Tempting for bounded memory, but the envelope's
resolution and window are *Visualization* decisions — baking a base bin size on the audio thread
leaks a Visualization parameter across the seam and caps dynamic zoom. The numbers also don't
justify it: 6 s of stereo raw is ~2.3 MB and re-folding ~800 new samples/frame is trivial, so there
is no cost to pay for. Reduction stays GUI-side.

**Each Module drains the ring itself.** `rtrb` is single-consumer — the first Module to `pop()` a
frame eats it for the others. One drainer fanning out a slice is the only correct shape, and it
keeps the per-sample loop inside each Module (monomorphized in its `update`) rather than as a virtual
call per sample.

**Store Waveform columns at display resolution.** A resizable window would orphan the history on
every resize (blank, scroll back in). Base-resolution storage makes resize a cheap re-merge. 0.5 ms
also marks the floor below which "envelope" stops being meaningful and the job belongs to the
Oscilloscope — so it doubles as the domain boundary between the two Modules.

## Consequences

- **The integration contract.** Every Module — Loudness included — is a GUI-side `FrameContext`
  *consumer* implementing the two-phase trait. None of them touch the audio thread; the audio
  thread's only job is to push raw samples (plus the legacy peak atomic).
- **`RenderWindow` becomes the host.** Ingest + linearise must move out of it into the drain/fan-out
  loop; the current waveform draw is already ~90 % of one `Module`.
- **Reset and config are GUI-local.** A Module's interactions (the Loudness reset per [0004], target,
  window length) live on the GUI side next to that Module's state — no signal crosses the audio→GUI
  seam. The seam stays strictly one-directional (audio→GUI).
- **`Measurements` stays tiny by default.** Because Modules derive their own measurements from the
  ring, `Measurements` carries only the rare cheap-and-shared scalar. If a genuinely loss-intolerant,
  certification-grade measurement is ever required, the escape hatch exists — but as a deliberate,
  documented exception, not the default. This is the discipline that keeps it from becoming a
  god-object.
- **Loss is asymmetric and deliberate.** Visuals — and now meters — tolerate the ring's
  drop-on-starve under a stalled GUI; a reader must not "fix" the drop-on-starve behavior thinking
  it's a bug. Size the ring deep enough that a drop requires a hung window.
- **Per-column store is shared with [0001].** Waveform columns carry min / max / mean-square **per
  channel** (L, R — this ADR) *plus* a **single shared set** of 3 band-energy floats for spectral
  coloring (0001; from the mono sum, so one set, not per channel). Merging must stay associative —
  store mean-square, never RMS; average mean-squares and `sqrt` at draw.
