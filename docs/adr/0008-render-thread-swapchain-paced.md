# The editor renders on a dedicated thread paced by the swapchain, not on the host's frame callback

The GUI renders from a dedicated thread that loops `drain → update → acquire → render → present`
forever. The blocking `Surface::get_current_texture()` (Fifo present, `desired_maximum_frame_latency =
2`) is the clock: it stalls until the presentation engine frees a drawable at vblank, so the loop
self-paces to the display **independent of the host's main run loop**. baseview's `on_frame` is a
no-op; baseview is otherwise untouched.

## Why — the bottleneck was the present *path*, not the clock

The waveform must scroll buttery-smooth (120Hz ProMotion) in every host. Logic and the standalone were
smooth; **FL Studio was lumpy** (and Ableton would be too). A long investigation chased the wrong
variable — *which clock wakes us to render* (CADisplayLink vs CVDisplayLink vs CAMetalDisplayLink,
advancing scroll by the display link's `targetTimestamp`). None of it helped, because in an embedded
plugin **the clock was never the bottleneck.**

The decisive observation: in FL, FL's *own* UI (playhead, meters) is smooth — so FL's compositor
presents at a steady 60Hz. The judder was that we only called `present` from baseview's `on_frame`,
and FL pumps that callback erratically (measured 0.4–47ms, sub-ms bursts then ~40ms gaps) because it
starves/over-pumps the main run loop. So a steady compositor was showing a **stale layer** — refreshed
on FL's cadence, not the display's. Every per-`on_frame` scheme inherits that erraticness.

Decoupling the render loop from `on_frame` fixes it at the source: we present every vblank regardless
of when (or whether) the host calls us, so FL's compositor always has a fresh frame. Async present
(`CAMetalLayer.presentsWithTransaction` defaults to `false`; wgpu doesn't override it) routes the
finished frame to the render server without waiting on the host's CATransaction commit.

## Consequences

- **The cadence detector and the time-based ("TIME mode") scroll path are obsolete.** Each loop
  iteration is exactly one vblank-paced present, so the waveform is always fixed-px. The detector read
  the swapchain's *bimodal* acquire timing (a free drawable returns instantly; then it blocks) as a
  "lumpy host" and flipped to TIME mode, which judders — so it is forced off and the whole machinery
  (cadence EMA, `cadence_regular`, the TIME cursor, `FrameContext::present_dt`, the debug reference
  rulers, baseview's `targetTimestamp` plumbing) is dead code to remove. See ADR 0007 / the waveform
  scroll model for what the fixed-px path does (drift is absorbed in per-column sample count).
- **Teardown is the crash-prone seam.** The render thread owns the `Surface`, which references the
  NSView's `CAMetalLayer`; `window.close()` frees that view. A **per-instance** `RenderControl`
  (deliberately NOT per-plugin `Shared` — a double-spawn would clobber a live thread's handle and
  use-after-free) stops + joins the thread in `EditorHandle::drop` *before* `window.close()`. The loop
  re-checks the stop flag immediately after the blocking acquire, so teardown waits at most one frame.
- **baseview's display link is now vestigial** — it drives the no-op `on_frame`. Left in place
  (untouched) so the fork stays minimal; its frame diagnostics now measure nothing useful.
- **Known un-hardened edge:** if the presentation engine is stalled at the instant of close (display
  asleep), the join can block briefly; safe during active use, flagged for hardening (bounded join
  with explicit view-lifetime management).

## Alternatives rejected (recorded so they are not re-litigated)

- **`CADisplayLink` on a secondary thread's run loop** — crashed FL (a run-loop API forced onto a
  thread whose run loop the host doesn't own) and beachballed (callback flood). A plain render loop has
  no run loop to corrupt; this is why the dedicated-thread approach is safe where the display-link one
  was not.
- **`CVDisplayLink` / `CAMetalDisplayLink` / `targetTimestamp`** — all are clock mechanisms; the clock
  was not the problem. `CVDisplayLink` is also deprecated; `CAMetalDisplayLink` wants to own Metal
  drawable delivery, conflicting with wgpu's surface management.
- **`desired_maximum_frame_latency = 1`** (2 drawables) — serializes CPU and GPU (wgpu's own docs warn
  this trades throughput for latency), starving us to ~95fps on a 120Hz panel → judder. `2` lets them
  pipeline while the blocking acquire still paces to vblank; one extra frame of latency is invisible on
  a meter.
