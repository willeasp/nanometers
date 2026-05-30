# Hand-roll BS.1770 loudness; keep `ebur128` only as a test oracle

The Loudness Module needs Momentary / Short-term / Integrated loudness per ITU-R BS.1770 /
EBU R128 — K-weighting, mean-square windowing, and the two-stage gated Integrated measurement. The
mature `ebur128` crate already computes all of this correctly (plus LRA and true-peak) and is
maintained. Per [0002] the measurement runs GUI-side, driven frame-by-frame off the ring drain,
which both a hand-roll and the crate satisfy equally. The rest of the renderer is deliberately
hand-rolled (the glow Oscilloscope), and the project values learning the domain and a lean shipped
binary — but loudness correctness, the gating especially, is fiddly and easy to get subtly wrong.

## The decision

**Hand-roll the BS.1770 chain ourselves** — K-weighting biquads, 100 ms-block mean-square, the M / S
sliding windows, the two-stage gated Integrated, and channel weighting — and **add `ebur128` as a
dev-dependency only**, used in tests as an oracle: feed reference signals (a −23 LUFS sine, pink
noise, gated silence cases) and assert our M / S / I match the crate within a tight tolerance
(~0.1 LU). The shipped binary never links `ebur128`.

## Why not use `ebur128` at runtime

- It is a real dependency in the shipped plugin for a computation that is a few hundred lines and
  sits squarely in the project's "learn the domain, stay lean" lane.
- We want full control of state and timing to fit the GUI-side frame-driven model and to share the
  100 ms-bin structure with future readouts.
- It is less educational, and understanding the standard is part of the point of the project.

The trade-off accepted is that **we own correctness**. That is mitigated by making `ebur128` the
test oracle: any divergence from the reference implementation fails the tests rather than shipping
silently.

## Consequences

- A `dev-dependencies: ebur128` entry, and conformance tests asserting M / S / I within ~0.1 LU on
  reference signals. These tests are the safety net the hand-roll leans on — they are not optional,
  and they are the first thing built (the DSP core is testable before any GPU or Module wiring).
- If LRA or true-peak is ever wanted and hand-rolling them proves not worth it, the runtime decision
  can be revisited per-measurement; the oracle tests make a later partial adoption of the crate safe
  to validate against.
- The hand-rolled DSP is module-internal. Its block sizes, gating thresholds, and channel weighting
  follow the standard and live with the module's spec and code doc-comments, not in this ADR.
