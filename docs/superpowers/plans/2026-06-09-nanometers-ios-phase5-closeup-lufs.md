# Nanometers iOS — Phase 5: Close-up Waveform + Live Short-term LUFS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the DJ-style close-up waveform (a frequency-colored strip scrolling past a fixed center playhead, driven by the sample-accurate player clock) and the live BS.1770 short-term LUFS meter (fed by the existing main-mixer tap), completing the v1 "soul features".

**Architecture:** Pure Swift wiring over machinery that already ships. The streaming meter C-ABI (`nano_meter_new/push/short_term/free`) is already built, exported in both `.a` slices of `NanoDSP.xcframework`, ABI-tested, and linked — Phase 5 only adds a thread-safe Swift wrapper and feeds it from the **existing** `installOutputMeter` tap. The close-up is a new SwiftUI `Canvas` sibling of `OverviewWaveform` that windows the **same cached `[WaveBin]`** (10 bins/sec, denser than the design's ~7 bars/sec target — no re-analysis) around a sample-accurate `centerTime`, paced by `TimelineView(.animation)` reading the engine clock each frame. The `@AppStorage("zoomWave")` toggle already exists in Settings (inert); Phase 5 makes `NowPlayingScreen` read it.

**Tech Stack:** Swift 5.10 / SwiftUI (iOS 18), `AVAudioEngine` main-mixer tap, `OSAllocatedUnfairLock` (os), `nano-dsp` C-ABI via `NanoDSP.xcframework`, XcodeGen, XCTest + XCUITest on the iOS 26.5 simulator.

**Working directory for all commands:** `apps/nano-ios` (from the worktree root). Simulator: `iPhone 17 Pro`, id `F8BC6E09-E5E4-4054-A03B-B1434DF0838D`, scheme `NanoMeters`, unit-test target `NanoMetersTests`, UI-test target `NanoMetersUITests`. **Run `xcodegen generate` whenever a task ADDS a new source/test file** (the project globs the `Sources/`/`Tests/` dirs at generation time).

---

## Design decisions (resolved from the spec, handoff §05, the JSX `NMScrollWave`, and the grounded code read)

- **No Rust / header / xcframework work.** The streaming meter is fully built and `nm`-verified in both slices. Phase 5 is Swift-only. Do **not** touch `crates/nano-dsp/**` or rebuild the xcframework.
- **Bin source = the existing cache.** `WaveformStore.shared.bins(for:)` (10 bins/sec) is already loaded in `NowPlayingScreen`. The close-up windows that array; it never re-analyzes (handoff §05 "one decode per file, ever"). 10/sec ≥ the design's ~7 bars/sec target.
- **Color = continuous.** Reuse `WaveBins.color(_:)` (ADR 0001); never remap to the 4 handoff hex tokens.
- **centerTime = the player-node sample clock**, read fresh each frame inside `TimelineView` — never a wall-clock/`performance.now()` interpolation (handoff §05 explicit). Expose `AudioEngine.centerTime` (seconds) computed off the existing private `currentFrame`.
- **Thread-safety:** the meter handle is **not** thread-safe. The wrapper serializes all access with one `OSAllocatedUnfairLock`; `feed` runs on the audio tap thread, `requestReset` from main. The handle is created/freed/used only inside the lock, so there is no cross-thread race. The wrapper lives **outside** `@MainActor` so the tap closure calls it directly (the existing tap already hops only a scalar to main).
- **Interleave on the audio thread.** The tap buffer is planar (`floatChannelData[0]=L,[1]=R`); `nano_meter_push` wants interleaved stereo. The wrapper interleaves into a reused scratch buffer. Mono content feeds `data[0]` as both channels (accepts the ~+3 LU stereo-sum offset — rare for music; documented, revisit if needed).
- **Meter sample rate = the tap buffer's** `format.sampleRate` (the mixer/output rate, which can differ from the file rate). The wrapper recreates the handle when the rate changes.
- **History reset on track change / seek** (no FFI reset): `requestReset()` drops the 3 s window on the next `feed`.
- **Badge value (decision — blank until live):** Now Playing binds the badge to `engine.shortTermLUFS` **directly**. It shows the live short-term reading while playing (it appears within ~100 ms and stabilizes toward the true 3 s value over the first ~3 s) and is **blank (`—`) whenever there's no live reading** — paused, stopped, or before the first audio renders. Blank-until-live deliberately signals the `S` value is genuinely live, not a stored number. The tap therefore publishes `shortTermLUFS` **only while `isPlaying`**, and `toggle()`'s resume branch calls `requestReset()` so the reading restarts clean (no paused-silence dilution). List rows (`NMLufsValue`) keep showing the per-track integrated value. The live value is transient engine state — **never** written to `Track.integratedLUFS`.
- **Pacing:** `TimelineView(.animation(paused: !isPlaying))` first (Canvas). The Metal escape hatch (spec risk 2 / handoff perf note) stays closed unless ProMotion profiling shows jank — out of scope here.
- **No new ADR.** Phase 5 introduces no new architecture decision; it operates within ADR 0001 (color), 0010 (iOS native SwiftUI, single FFI seam), and the spec's Canvas-first decision. The plan notes this explicitly so no ADR task is expected.

---

## File Structure

**New:**
- `apps/nano-ios/Sources/Components/CloseUpWaveform.swift` — the close-up `Canvas` view + `enum CloseUpMath` (the testable time→bar-index math). One responsibility: render a windowed, scrolling slice of cached bins past a fixed center playhead.
- `apps/nano-ios/Tests/CloseUpMathTests.swift` — pure unit tests for `CloseUpMath`.

**Modified:**
- `apps/nano-ios/Sources/DSP/NanoDSPBridge.swift` — add `final class LiveLUFSMeter` (the streaming-meter wrapper). Keeps the "only file that imports `NanoDSP`" invariant (ADR 0010).
- `apps/nano-ios/Sources/Playback/AudioEngine.swift` — add `centerTime`, `shortTermLUFS`, the `liveMeter`, feed the tap, and reset history on load/seek/stop.
- `apps/nano-ios/Sources/Screens/NowPlayingScreen.swift` — read `@AppStorage("zoomWave")`, mount `CloseUpWaveform` above the overview scrubber, rebind the badge to the live value.
- `apps/nano-ios/Tests/NanoDSPLinkTests.swift` — add a streaming-meter link test.
- `apps/nano-ios/Tests/AudioEngineTests.swift` — add a real-playback test that the live short-term value becomes a plausible reading.
- `apps/nano-ios/UITests/WaveformUITests.swift` — add a test that the close-up appears when `zoomWave` is enabled.

---

### Task 1: `LiveLUFSMeter` — the streaming short-term meter Swift wrapper

**Files:**
- Modify: `apps/nano-ios/Sources/DSP/NanoDSPBridge.swift`
- Test: `apps/nano-ios/Tests/NanoDSPLinkTests.swift`

- [ ] **Step 1: Write the failing test** — append this method inside `final class NanoDSPLinkTests` in `apps/nano-ios/Tests/NanoDSPLinkTests.swift`:

```swift
    func test_liveMeterReadsShortTermFromATone() {
        let sr = 48_000.0
        let n = Int(sr * 4.0)                                   // ~4 s → the 3 s short-term window fills
        var tone = [Float](repeating: 0, count: n)
        for i in 0..<n { tone[i] = 0.5 * sinf(2.0 * .pi * 1000.0 * Float(i) / Float(sr)) }

        let meter = LiveLUFSMeter()
        var last: Double?
        let chunk = 1024
        var off = 0
        while off < n {
            let f = min(chunk, n - off)
            tone.withUnsafeBufferPointer { p in
                let base = p.baseAddress! + off
                last = meter.feed(left: base, right: base, frames: f, sampleRate: sr)   // mono → L=R
            }
            off += f
        }
        XCTAssertNotNil(last, "no short-term reading after ~4 s of tone (link or wiring failure)")
        XCTAssertTrue((last ?? 0) > -40 && (last ?? 0) < 0,
                      "short-term implausible: \(String(describing: last))")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `apps/nano-ios`):
```bash
xcodebuild test -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/NanoDSPLinkTests/test_liveMeterReadsShortTermFromATone 2>&1 | tail -20
```
Expected: **compile failure** — `cannot find 'LiveLUFSMeter' in scope`.

- [ ] **Step 3: Implement `LiveLUFSMeter`** — in `apps/nano-ios/Sources/DSP/NanoDSPBridge.swift`, add `import os` at the top (below `import NanoDSP`) and append this class after the `NanoDSPBridge` enum (same file keeps the single `import NanoDSP` seam, ADR 0010):

```swift
/// Streaming short-term (3 s) BS.1770 meter (`nano_meter_*`). The C handle is NOT thread-safe, so
/// every access is serialized by one `OSAllocatedUnfairLock`: `feed` runs on the audio tap thread,
/// `requestReset` from the main actor. The handle is created/freed/used only inside the lock — no
/// cross-thread race — and the class lives outside `@MainActor` so the tap closure calls it directly.
/// Mirrors crates/nano-dsp/smoke/smoke.swift; the Rust side is pinned by tests/ffi_abi.rs.
final class LiveLUFSMeter: @unchecked Sendable {
    private struct State {
        var handle: OpaquePointer?        // NanoMeter* (opaque)
        var rate: Double = 0
        var resetPending = false
    }
    private let lock = OSAllocatedUnfairLock(uncheckedState: State())

    /// Drop the 3 s history on the next `feed` (call on track change / seek). Cheap; any thread.
    func requestReset() { lock.withLock { $0.resetPending = true } }

    /// Interleave planar L/R, push, and read short-term LUFS. Called on the audio tap thread.
    /// Recreates the handle when the sample rate changes or a reset is pending. nil = no reading.
    func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) -> Double? {
        guard frames > 0 else { return nil }
        // Interleave OUTSIDE the lock into a `let` array (Sendable): `withLock`'s body is @Sendable and
        // cannot capture the raw L/R pointers (a warning in the project's Swift 5.10 mode, a hard error
        // under Swift 6). The array crosses the boundary cleanly; its pointer is created and used
        // entirely inside the lock. One small alloc per callback — fine for a ~1024-frame tap.
        let interleaved: [Float] = {
            var buf = [Float](repeating: 0, count: frames * 2)
            for i in 0..<frames { buf[2 * i] = left[i]; buf[2 * i + 1] = right[i] }
            return buf
        }()
        return lock.withLock { st -> Double? in
            if st.handle == nil || st.rate != sampleRate || st.resetPending {
                if let h = st.handle { nano_meter_free(h) }
                st.handle = sampleRate > 0 ? nano_meter_new(sampleRate) : nil
                st.rate = sampleRate
                st.resetPending = false
            }
            guard let h = st.handle else { return nil }
            interleaved.withUnsafeBufferPointer { nano_meter_push(h, $0.baseAddress, frames) }
            let v = nano_meter_short_term(h)
            return v.isFinite ? v : nil
        }
    }

    /// Free the handle (call when playback stops entirely).
    func stop() { lock.withLock { st in if let h = st.handle { nano_meter_free(h) }; st.handle = nil; st.rate = 0 } }

    deinit { lock.withLock { st in if let h = st.handle { nano_meter_free(h) } } }
}
```

> If the generated `NanoDSP` interface imports the handle as `OpaquePointer!` (implicitly-unwrapped, no nullability annotations in the header) the code above still compiles — `OpaquePointer?` accepts it. Confirm against the build if the compiler objects.

- [ ] **Step 4: Run the test to verify it passes**

Run the same command as Step 2. Expected: **TEST SUCCEEDED**, `test_liveMeterReadsShortTermFromATone` passes (and the existing `test_bridgeAnalyzesAndMeasuresASynthTone` still passes).

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/DSP/NanoDSPBridge.swift apps/nano-ios/Tests/NanoDSPLinkTests.swift
git commit -m "feat(ios): LiveLUFSMeter — Swift wrapper over the streaming nano_meter_* C-ABI

The streaming short-term meter already ships in NanoDSP.xcframework (both
slices, ABI-tested); this adds the only missing layer — a lock-serialized
Swift wrapper that interleaves planar L/R and reads 3 s short-term LUFS.
Kept in NanoDSPBridge.swift so nano-dsp stays imported in exactly one file
(ADR 0010).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 2: `AudioEngine` — `centerTime`, live `shortTermLUFS`, tap feed + history lifecycle

**Files:**
- Modify: `apps/nano-ios/Sources/Playback/AudioEngine.swift`
- Test: `apps/nano-ios/Tests/AudioEngineTests.swift`

- [ ] **Step 1: Write the failing test** — append inside `final class AudioEngineTests` in `apps/nano-ios/Tests/AudioEngineTests.swift` (mirrors the existing `writeSine` real-audio test; a 5 s tone so the 3 s short-term window fills):

```swift
    func test_liveShortTermLUFSBecomesAPlausibleReadingWhilePlaying() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 5.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)

        // Let > 3 s render so the 3 s short-term window is well-populated (it reads live within ~100 ms).
        try await Task.sleep(nanoseconds: 3_800_000_000)
        let s = engine.shortTermLUFS
        XCTAssertNotNil(s, "expected a live short-term reading after ~3.8 s, got nil")
        XCTAssertTrue((s ?? 0) > -40 && (s ?? 0) < 0, "live short-term implausible: \(String(describing: s))")

        engine.toggle()   // pause → blank-until-live: the badge value clears
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(engine.shortTermLUFS, "live short-term should blank when paused")
    }

    func test_centerTimeAdvancesWhilePlaying() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 3.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertGreaterThan(engine.centerTime, 0.3, "centerTime should advance with the sample clock")
    }
```

- [ ] **Step 2: Run the tests to verify they fail**

Run (from `apps/nano-ios`):
```bash
xcodebuild test -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/AudioEngineTests 2>&1 | tail -20
```
Expected: **compile failure** — `value of type 'AudioEngine' has no member 'shortTermLUFS'` / `'centerTime'`.

- [ ] **Step 3a: Add the published state + the meter** — in `apps/nano-ios/Sources/Playback/AudioEngine.swift`, after the `outputLevel` property (line ~24) add:

```swift
    /// Live short-term (3 s) BS.1770 loudness, fed by the main-mixer tap. A reading appears within
    /// ~100 ms of playback (one closed 100 ms bin) and stabilizes over the first ~3 s; nil only before
    /// the first audio renders, right after a reset (until the next feed), or on true silence.
    /// Transient — NOT persisted on Track.
    private(set) var shortTermLUFS: Double?
```

After the `player`/`file` private fields (near line ~38) add:

```swift
    /// Streaming short-term loudness, fed from `installOutputMeter`'s tap. Off-main + lock-guarded.
    private let liveMeter = LiveLUFSMeter()
```

After the `currentFrame` computed property (line ~175) add the public sample-accurate clock the close-up reads each frame:

```swift
    /// Sample-accurate playback position in seconds — the close-up's `centerTime`. Reads the player
    /// node clock live (handoff §05: derive from sample time, never a wall clock).
    var centerTime: Double { sampleRate > 0 ? Double(currentFrame) / sampleRate : 0 }
```

- [ ] **Step 3b: Feed the meter from the existing tap** — replace `installOutputMeter()` (lines ~59-66) with:

```swift
    private func installOutputMeter() {
        let meter = liveMeter        // capture the off-main, lock-guarded handle for the tap thread
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let frames = Int(buffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(frames))
            let stereo = buffer.format.channelCount > 1
            let s = meter.feed(left: data[0], right: stereo ? data[1] : data[0],
                               frames: frames, sampleRate: buffer.format.sampleRate)
            Task { @MainActor in
                guard let self else { return }
                self.outputLevel = rms
                self.shortTermLUFS = self.isPlaying ? s : nil   // live ONLY while playing; blank otherwise
            }
        }
    }
```

- [ ] **Step 3c: Reset history on load / seek / stop.** Make these edits in `AudioEngine.swift`:

  In `loadAndStart(_:)`, the reset line near the top (line ~105) — add the meter reset:
```swift
        progress = 0; elapsed = 0; seekOffsetFrames = 0
        liveMeter.requestReset(); shortTermLUFS = nil          // drop stale 3 s window for the new track
```
  In `loadAndStart(_:)`, the unresolved-file early return (line ~109) and the `catch` (line ~127) — both set `file = nil`; add `liveMeter.stop(); shortTermLUFS = nil` to each so a non-playing selection clears the meter. Example for the guard branch:
```swift
            current = track; isPlaying = false; file = nil; totalFrames = 0
            liveMeter.stop(); shortTermLUFS = nil
            updateNowPlayingInfo()
```
  In `toggle()`, the resume (`else`) branch (line ~86-89) — drop any paused silence so the live reading restarts clean (the tap's `isPlaying` gate already blanks the badge while paused, so pause needs no extra code):
```swift
        } else {
            if !engine.isRunning { try? engine.start() }
            player.play(); isPlaying = true; startTicker()
            liveMeter.requestReset()                       // fresh 3 s window on resume
        }
```
  In `seek(toFraction:)` (after the `guard`, line ~242) — clear the pre-seek window:
```swift
        liveMeter.requestReset(); shortTermLUFS = nil
```
  In `next()`, the end-of-queue stop branch (line ~205-208) — add alongside `isPlaying = false`:
```swift
            isPlaying = false; progress = 0; elapsed = 0
            liveMeter.stop(); shortTermLUFS = nil
```

- [ ] **Step 4: Run the tests to verify they pass**

Run the Step 2 command. Expected: **TEST SUCCEEDED** — both new tests pass and the existing `test_playbackProducesNonSilentOutput_thenSilenceWhenPaused` still passes (the `outputLevel` line is unchanged).

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Playback/AudioEngine.swift apps/nano-ios/Tests/AudioEngineTests.swift
git commit -m "feat(ios): live short-term LUFS + sample-accurate centerTime on AudioEngine

Extend the existing main-mixer tap to interleave L/R and feed the streaming
meter, publishing shortTermLUFS (~per callback, hopped to main like outputLevel);
reset the 3 s window on track change / seek / stop. Expose centerTime (seconds)
off the player-node clock for the close-up.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 3: `CloseUpWaveform` + `CloseUpMath`

**Files:**
- Create: `apps/nano-ios/Sources/Components/CloseUpWaveform.swift`
- Test: `apps/nano-ios/Tests/CloseUpMathTests.swift`

- [ ] **Step 1: Write the failing test** — create `apps/nano-ios/Tests/CloseUpMathTests.swift`:

```swift
import XCTest
@testable import NanoMeters

final class CloseUpMathTests: XCTestCase {
    func test_playIndexMapsTimeToFractionalBar() {
        // 2000 bins over 200 s = 10 bins/sec; 5 s → bar 50.
        XCTAssertEqual(CloseUpMath.playIndex(centerTime: 5, binCount: 2000, duration: 200), 50, accuracy: 1e-9)
        XCTAssertEqual(CloseUpMath.playIndex(centerTime: 0, binCount: 2000, duration: 200), 0, accuracy: 1e-9)
    }

    func test_playIndexClampsAndGuards() {
        XCTAssertEqual(CloseUpMath.playIndex(centerTime: -3, binCount: 100, duration: 10), 0, accuracy: 1e-9)
        XCTAssertEqual(CloseUpMath.playIndex(centerTime: 5, binCount: 0, duration: 0), 0, accuracy: 1e-9)
    }
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `apps/nano-ios`):
```bash
xcodegen generate >/dev/null && xcodebuild test -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/CloseUpMathTests 2>&1 | tail -20
```
Expected: **compile failure** — `cannot find 'CloseUpMath' in scope` (after `xcodegen` picks up the new test file).

- [ ] **Step 3: Implement the view + math** — create `apps/nano-ios/Sources/Components/CloseUpWaveform.swift`:

```swift
import SwiftUI

/// DJ-style close-up waveform (handoff §05A / prototype `NMScrollWave`): a ~9 s window of the cached
/// bins scrolling right→left past a FIXED center playhead, driven by the sample-accurate `centerTime`.
/// Pure: it windows the same cached `[WaveBin]` the overview uses (never re-analyzed), reuses the
/// continuous `WaveBins.color`, and is paced by `TimelineView(.animation)` reading the engine clock
/// each frame (not a wall-clock interpolation). The played side dims to 0.42; both edges fade out.
struct CloseUpWaveform: View {
    var bins: [WaveBin]
    var currentTime: () -> Double      // sample-accurate seconds, read fresh each animated frame
    var duration: Double
    var coloringOn: Bool = true
    var isPlaying: Bool
    /// Observed seek/elapsed value (pass `engine.elapsed`). While playing, `TimelineView` animates off
    /// the live `currentTime()` clock; while PAUSED the schedule is frozen, so this value changing on a
    /// scrub is what forces a re-render to re-center the held frame (handoff §05: a scrub re-centers the
    /// close-up even when paused). Not read in `draw` — its change alone re-renders the view.
    var redrawTrigger: Double
    var height: CGFloat = 56           // §05: 56pt strip

    private let secVisible: CGFloat = 9

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { _ in
            Canvas { ctx, size in draw(ctx, size, center: currentTime()) }
        }
        .frame(height: height)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            Text("CLOSE-UP").font(Theme.mono(8.5, .semibold)).tracking(1.4)
                .foregroundStyle(.white.opacity(0.42)).padding(.top, 7).padding(.leading, 10)  // §05 left:10 top:7
        }
        .accessibilityElement()
        .accessibilityIdentifier("closeUpWaveform")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, center: Double) {
        guard !bins.isEmpty, duration > 0 else { return }
        let w = size.width, h = size.height
        let barsPerSec = Double(bins.count) / duration
        let playIdx = CloseUpMath.playIndex(centerTime: center, binCount: bins.count, duration: duration)
        let pxPerBar = (w / secVisible) / CGFloat(barsPerSec)
        guard pxPerBar > 0 else { return }
        let centerX = w / 2, centerY = h / 2
        let bw = max(1.4, pxPerBar * 0.6)
        let span = Int((Double(centerX / pxPerBar)).rounded(.up)) + 2
        let lo = max(0, Int(playIdx.rounded(.down)) - span)
        let hi = min(bins.count, Int(playIdx.rounded(.up)) + span)
        guard lo < hi else { return }

        for i in lo..<hi {
            let b = bins[i]
            let x = centerX + CGFloat(Double(i) - playIdx) * pxPerBar
            if x < -3 || x > w + 3 { continue }
            let bh = max(2, CGFloat(b.peak) * (h - 6))
            let played = Double(i) < playIdx
            let edge = min(1, (centerX - abs(x - centerX)) / (w * 0.14))     // §05 edge fade
            let alpha = (played ? 0.42 : 1.0) * Double(max(0, edge))
            let base = coloringOn ? WaveBins.color(b) : Theme.accent
            let rect = CGRect(x: x - bw / 2, y: centerY - bh / 2, width: bw, height: bh)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(bw / 2, 1.6)), with: .color(base.opacity(alpha)))
        }

        // Fixed center playhead: 2pt line + 2.6pt cap dots (§05 / NMScrollWave).
        ctx.fill(Path(CGRect(x: centerX - 1, y: 1, width: 2, height: h - 2)), with: .color(.white.opacity(0.92)))
        ctx.fill(Path(ellipseIn: CGRect(x: centerX - 2.6, y: 4 - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: centerX - 2.6, y: h - 4 - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
    }
}

/// Pure time→bar-index math for the close-up (testable without a view). `barsPerSec` is derived from
/// the actual cached density (handoff: ~7/sec target; cache is 10/sec), so short tracks (floored at
/// 150 bins) map correctly without assuming a constant.
enum CloseUpMath {
    /// Fractional bar index at the playhead for a sample-accurate `centerTime` (seconds).
    static func playIndex(centerTime: Double, binCount: Int, duration: Double) -> Double {
        guard duration > 0, binCount > 0 else { return 0 }
        let barsPerSec = Double(binCount) / duration
        return max(0, centerTime) * barsPerSec
    }
}
```

- [ ] **Step 4: Run the test to verify it passes**

Run the Step 2 command. Expected: **TEST SUCCEEDED**, `CloseUpMathTests` passes.

- [ ] **Step 5: Commit**

(The regenerated `NanoMeters.xcodeproj` is **gitignored** — it's generated from `project.yml` via XcodeGen and never committed, so stage only the two new source files.)

```bash
git add apps/nano-ios/Sources/Components/CloseUpWaveform.swift apps/nano-ios/Tests/CloseUpMathTests.swift
git commit -m "feat(ios): CloseUpWaveform — DJ-style scrolling strip past a fixed playhead

A Canvas sibling of OverviewWaveform that windows the same cached [WaveBin]
(~9 s visible, fixed center playhead + cap dots, 0.42 played alpha, edge fade),
paced by TimelineView(.animation) reading the engine clock each frame. Time→bar
mapping is factored into a pure CloseUpMath for unit tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 4: Mount the close-up in `NowPlayingScreen` + rebind the live badge

**Files:**
- Modify: `apps/nano-ios/Sources/Screens/NowPlayingScreen.swift`
- Test: `apps/nano-ios/UITests/WaveformUITests.swift`

- [ ] **Step 1: Write the failing UI test** — append inside `final class WaveformUITests` in `apps/nano-ios/UITests/WaveformUITests.swift`:

```swift
    @MainActor
    func test_closeUpAppearsWhenZoomWaveEnabled() {
        let app = XCUIApplication()
        // -autoplay docks a track, -expand opens Now Playing; -zoomWave YES lands in the UserDefaults
        // argument domain so @AppStorage("zoomWave") reads true without touching app code.
        app.launchArguments += ["-autoplay", "-expand", "-zoomWave", "YES"]
        app.launch()

        XCTAssertTrue(app.otherElements["nowPlaying"].waitForExistence(timeout: 8),
                      "Now Playing should auto-open")
        XCTAssertTrue(app.otherElements["closeUpWaveform"].waitForExistence(timeout: 5),
                      "close-up should render when zoomWave is on")
    }
```

- [ ] **Step 2: Run the test to verify it fails**

Run (from `apps/nano-ios`):
```bash
xcodebuild test -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersUITests/WaveformUITests/test_closeUpAppearsWhenZoomWaveEnabled 2>&1 | tail -20
```
Expected: **test failure** — `closeUpWaveform` never appears (the screen doesn't read `zoomWave` yet).

> This test relies on the `#if DEBUG` `-autoplay`/`-expand` hooks in `RootView` to dock a track and open Now Playing, so it requires the default **Debug** test build (`xcodebuild test` uses Debug by default — fine). `-zoomWave YES` works independently via the UserDefaults argument domain.

- [ ] **Step 3: Wire it into `NowPlayingScreen.swift`.**

  Add the toggle read alongside the existing `@AppStorage` (after line ~17 `@AppStorage("spectrum")`):
```swift
    @AppStorage("zoomWave") private var zoomWave = false        // close-up (DJ scroll); off in v1
```
  Insert the close-up row in `body`'s `VStack` (lines ~26-34) between `titleRow` and `scrubber`:
```swift
                topBar
                hero
                titleRow
                closeUp          // §05/§03D: close-up sits above the full-song scrubber
                scrubber
                timeRow
                transportRow
                volumeRow
                bottomRail
```
  Add the `closeUp` ViewBuilder (next to the other `@ViewBuilder` props, e.g. after `scrubber`):
```swift
    @ViewBuilder private var closeUp: some View {
        if zoomWave, !bins.isEmpty, let dur = engine.current?.durationSec, dur > 0 {
            CloseUpWaveform(bins: bins,
                            currentTime: { engine.centerTime },
                            duration: dur,
                            coloringOn: spectrum,
                            isPlaying: engine.isPlaying,
                            redrawTrigger: engine.elapsed)   // observed → re-centers on scrub-while-paused
        }
    }
```
  Rebind the badge in `scrubber` (line ~62) from the per-track integrated value to the live short-term value (blank `—` when there's no live reading — see the blank-until-live decision):
```swift
                    LUFSBadge(lufs: engine.shortTermLUFS).offset(y: -6)
```

- [ ] **Step 4: Run the test to verify it passes**

Run the Step 2 command. Expected: **TEST SUCCEEDED** — the close-up appears. Then run the full waveform/now-playing UI suites to confirm no regression:
```bash
xcodebuild test -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersUITests/WaveformUITests \
  -only-testing:NanoMetersUITests/NowPlayingUITests 2>&1 | tail -20
```
Expected: all pass (the overview test, the existing zoom-transition tests, and the new close-up test).

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Screens/NowPlayingScreen.swift apps/nano-ios/UITests/WaveformUITests.swift
git commit -m "feat(ios): mount the close-up in Now Playing + live short-term badge

NowPlayingScreen now reads @AppStorage(zoomWave) and renders CloseUpWaveform
above the overview scrubber, and the LUFS badge shows the live short-term value
(falling back to the track's integrated value before ~3 s / when stopped).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

### Task 5: Full verification + visual gate

**Files:** none (verification only).

- [ ] **Step 1: Full unit + UI suite green**

Run (from `apps/nano-ios`):
```bash
xcodegen generate >/dev/null && xcodebuild test -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -25
```
Expected: **TEST SUCCEEDED**, no failures across `NanoMetersTests` + `NanoMetersUITests`.

- [ ] **Step 2: Visual gate — screenshot the live close-up**

```bash
xcrun simctl launch F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios -autoplay -expand -zoomWave YES
# wait ~5 s for playback so the short-term badge populates, then:
xcrun simctl io F8BC6E09-E5E4-4054-A03B-B1434DF0838D screenshot /tmp/phase5-closeup.png
```
Confirm by eye against handoff §05 / `NMScrollWave`: the close-up strip sits above the overview with a fixed center playhead (line + cap dots), bars scroll and fade at the edges, the played side is dimmer, and the badge shows a live `S  -NN.N  LUFS` number (not `—`). Send `/tmp/phase5-closeup.png` to the user as the visual gate. The live-meter *correctness* is covered by the Task 1/2 unit tests; the live *update* is a manual visual check (headless capture of the rendered audio is deferred per the self-testing memory).

- [ ] **Step 3: Confirm no plugin/TUI impact**

No `crates/**` files changed, so the desktop plugin/TUI are untouched. Sanity check the diff scope:
```bash
git diff --stat main -- 'crates/**'
```
Expected: **empty** (Phase 5 is iOS-only). If non-empty, something went wrong — investigate before finishing.

- [ ] **Step 4: Finish the branch** — REQUIRED SUB-SKILL: use `superpowers:finishing-a-development-branch`. (Phase 5 completes the v1 plan; the worktree branch merges to main the same way Phases 0–4 did — fast-forward / linear, confirm with the user before merging.)

---

## Self-Review

- **Spec coverage:** close-up (§05A: 9 s window, ~7 bars/sec satisfied by the 10/sec cache, fixed center playhead + cap dots, 0.42 played alpha, edge fade, 56pt strip, TimelineView reading the engine clock) → Task 3 + 4; live short-term LUFS (§05C: 3 s window, ~10 Hz, main-mixer tap, `S -9.5 LUFS` format) → Task 1 + 2 (the existing `LUFSBadge` already matches the format) + 4; `zoomWave` gate → Task 4; "one decode per file" (no re-analysis) honored (close-up windows the cached array). The Phase 5 scope lines 224-225 of the design spec are fully covered.
- **No placeholders:** every step has exact paths, complete code, runnable commands, and expected output. No TBDs.
- **Type/name consistency:** `LiveLUFSMeter.feed(left:right:frames:sampleRate:) -> Double?`, `requestReset()`, `stop()` (Task 1) are used verbatim by `AudioEngine` (Task 2); `AudioEngine.shortTermLUFS`/`centerTime` (Task 2) are used verbatim by `NowPlayingScreen` (Task 4); `CloseUpWaveform(bins:currentTime:duration:coloringOn:isPlaying:redrawTrigger:)` + `CloseUpMath.playIndex(centerTime:binCount:duration:)` (Task 3) match their call sites (Task 4) and tests. `WaveBin.peak/r/g/b`, `WaveBins.color`, `Theme.mono/accent` match the current source.
- **Risk retired first:** Task 1 proves the FFI wrapper in isolation before any UI depends on it (spec risk 1 pattern).
