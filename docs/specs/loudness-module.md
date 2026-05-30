# Loudness Module — build spec

The build contract for the Loudness Module. An agent should be able to build it from this file plus
the linked ADRs without reading the design conversation. Durable decisions only — volatile mechanics
(exact buffer sizes, struct shapes) live in code doc-comments once written. Glossary terms
(Loudness Module, LUFS, LU, Momentary/Short-term/Integrated, K-weighting, Gating, Reset, Target) are
defined in `CONTEXT.md`.

## Purpose & display

A Module showing loudness per ITU-R BS.1770 / EBU R128. It displays the three time scales —
**Momentary, Short-term, Integrated** — as vertical bars plus numeric readouts. The numeric values
are the first milestone; the bars and the LU scale follow.

## Inherited constraints (read these)

- **[0002]** — runs **screen-side**, fed by the single ring drain via `FrameContext`. The audio
  thread is not involved; it only pushes raw samples.
- **[0003]** — placement, width, and persistence are the host's; the Module owns an opaque `config`
  blob (its `Target`, scale, which time scale is prominent). It must not assume where it sits.
- **[0004]** — the Reset is a Module input consumer: `on_event` returns `Captured` for a click on the
  reset affordance, `Ignored` otherwise.
- **[0005]** — numeric readouts render with `wgpu_text` + the embedded OFL font, positioned inside the
  Module's own `viewport: Rect` and clipped with `set_scissor_rect`.
- **[0006]** — the BS.1770 DSP is **hand-rolled**; `ebur128` is a dev-dependency test oracle only.

## DSP contract

All measurement is GUI-side, folded online from each `FrameContext`'s new samples.

- **K-weighting** — two biquads in series per channel (stage 1 high-shelf "head" filter, stage 2
  high-pass / RLB curve). Coefficients are **sample-rate dependent** — compute them from the rate,
  rebuild on change. Filter state is per channel and must see samples in order (the ring is FIFO).
- **Block unit** — accumulate K-weighted mean-square into **100 ms bins**, the shared atomic unit:
  - **Momentary** = last **4 bins** (400 ms).
  - **Short-term** = last **30 bins** (3 s).
  - **Integrated** gating blocks = 400 ms windows every 100 ms (75 % overlap = 4 bins each).
- **Integrated** — keep a **growing `Vec`** of per-block mean-squares since the last reset (cap at a
  24 h runaway guard). Two-stage gate, exact over the whole take: absolute gate at **−70 LUFS**, then
  a relative gate at **mean − 10 LU**; average the survivors. Recompute on read (GUI thread, cheap).
- **Channel weighting** — from the declared input layout: **mono → one channel** (weight 1.0);
  **stereo → sum L + R**. ⚠️ The plugin duplicates a mono input to L = R in `process`; summing that
  reads **+3 LU hot**, so mono must measure a single channel. Do not skip this.
- **Loudness** — `LUFS = −0.691 + 10·log10(z)`, where `z` is the (channel-weighted) mean-square.

## Interfaces

- Implements the `Module` trait ([0002]): `update(&FrameContext, &Queue)` folds new samples;
  `render(&mut RenderPass, viewport: Rect)` draws; `on_event(&Event, viewport) -> EventStatus`
  handles the reset click.
- Reads `sample_rate` and `mono` from small atomics in `Shared` (set by the audio thread in
  `initialize`). While `sample_rate` is 0 (unknown), the meter idles.

## Reset semantics

GUI-local: clears the Integrated `Vec` and any held maxima, starts fresh. No signal crosses the
audio→GUI seam ([0002]). Interim, before the reset affordance exists, the meter starts fresh when the
editor opens (state is created in the Module's constructor).

## Acceptance criteria

Conformance tests (the safety net per [0006], built first, before any GPU/Module wiring): feed
reference signals — a **−23 LUFS sine**, **pink noise**, and **gated-silence** cases — and assert
Momentary / Short-term / Integrated match `ebur128` within **~0.1 LU**.

## Out of scope (for now)

True Peak (dBTP) and LRA. The bar scale / Target selection (EBU +9/+18, −23 vs −14) is a later
display milestone — Module-owned config per [0003], not part of the first numeric readout.
