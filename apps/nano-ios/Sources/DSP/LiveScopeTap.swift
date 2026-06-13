import Foundation
import os

/// A lock-guarded ring of the most recent stereo frames from the engine's mixer tap, for the live
/// analysis meters (goniometer + spectrum). The audio-tap thread copies frames in (`feed`); the
/// main-actor UI reads the newest `count` frames (`snapshot`) each display frame. Separate from
/// `LiveLUFSMeter` (which holds BS.1770 loudness state) — this keeps raw samples for the scope
/// visuals. `@unchecked Sendable`: every access goes through the one `OSAllocatedUnfairLock`.
final class LiveScopeTap: @unchecked Sendable {
    private let capacity: Int
    private struct State {
        var l: [Float]
        var r: [Float]
        var head: Int = 0       // next write index (wraps)
        var count: Int = 0      // valid frames buffered (≤ capacity)
        var total: Int = 0      // monotonic frames ever written — absolute timeline for smooth scanning
        var rate: Double = 0
    }
    private let lock: OSAllocatedUnfairLock<State>

    /// Capacity ≥ the largest read span. The goniometer's `ScopeCursor` can read up to ~maxLag (0.30 s)
    /// + its window behind the head, so size for ~0.5 s of stereo frames (≈ 24k @ 48 kHz) with slack —
    /// well above the spectrum's 2048-frame FFT window too.
    init(capacity: Int = 24_000) {
        self.capacity = capacity
        lock = OSAllocatedUnfairLock(
            initialState: State(l: [Float](repeating: 0, count: capacity),
                                r: [Float](repeating: 0, count: capacity)))
    }

    /// Copy `frames` of planar L/R into the ring (audio-tap thread). Copies the raw pointers into
    /// Sendable arrays before the lock body (a Swift 6 `@Sendable` closure can't capture the pointers).
    func feed(left: UnsafePointer<Float>, right: UnsafePointer<Float>, frames: Int, sampleRate: Double) {
        guard frames > 0 else { return }
        let lcopy = Array(UnsafeBufferPointer(start: left, count: frames))
        let rcopy = Array(UnsafeBufferPointer(start: right, count: frames))
        lock.withLock { st in
            st.rate = sampleRate
            for i in 0..<frames {
                st.l[st.head] = lcopy[i]
                st.r[st.head] = rcopy[i]
                st.head = (st.head + 1) % capacity
            }
            st.count = min(capacity, st.count + frames)
            st.total += frames
        }
    }

    /// Total frames ever written (monotonic) and the current sample rate — the absolute clock the
    /// goniometer's `ScopeCursor` scans against so it can animate smoothly between chunky tap deliveries.
    var written: Int { lock.withLock { $0.total } }
    var sampleRate: Double { lock.withLock { $0.rate } }

    /// `count` frames ending at absolute frame `end` (exclusive), oldest→newest. Frames that have
    /// scrolled out of the ring (or not yet arrived) read as 0. Lets a reader scan a smooth window
    /// through the buffered history at display rate, instead of only ever seeing the newest chunk.
    func window(endingAt end: Int, count: Int) -> (l: [Float], r: [Float], sampleRate: Double) {
        lock.withLock { st in
            let n = max(0, count)
            guard n > 0, st.count > 0 else { return ([], [], st.rate) }
            let endC = min(max(end, 0), st.total)
            let start = endC - n
            let oldest = st.total - st.count          // oldest absolute frame still buffered
            var l = [Float](repeating: 0, count: n)
            var r = [Float](repeating: 0, count: n)
            for i in 0..<n {
                let abs = start + i
                if abs >= oldest && abs < st.total {
                    let idx = ((abs % capacity) + capacity) % capacity
                    l[i] = st.l[idx]; r[i] = st.r[idx]
                }
            }
            return (l, r, st.rate)
        }
    }

    /// The most recent `count` frames, oldest→newest (fewer if not yet filled). Read on the main actor.
    func snapshot(_ count: Int) -> (l: [Float], r: [Float], sampleRate: Double) {
        lock.withLock { st in
            let n = min(max(0, count), st.count)
            guard n > 0 else { return ([], [], st.rate) }
            var l = [Float](repeating: 0, count: n)
            var r = [Float](repeating: 0, count: n)
            var idx = ((st.head - n) % capacity + capacity) % capacity   // oldest of the last n
            for i in 0..<n {
                l[i] = st.l[idx]; r[i] = st.r[idx]
                idx = (idx + 1) % capacity
            }
            return (l, r, st.rate)
        }
    }

    /// Drop buffered history (call on track change / seek). Cheap; any thread. Resets `total` with
    /// `head` so the absolute-frame → ring-index mapping stays consistent for `window(endingAt:)`.
    func reset() { lock.withLock { st in st.count = 0; st.head = 0; st.total = 0 } }
}

/// Smoothly scans the live scope ring at display rate. The audio tap delivers ~100 ms chunks (~10 Hz),
/// so a meter that always reads "the newest N frames" only changes 10×/s. Instead this holds an absolute
/// end-of-window read position that advances by REAL elapsed time each frame and trails the write head by
/// a small latency — so there's always buffered audio to scan through, and the goniometer animates at the
/// display rate (60/120 Hz). A reference type so per-frame state survives view re-eval without invalidation.
final class ScopeCursor {
    private var pos = 0.0
    private var lastNow = 0.0
    private var seeded = false

    private let lagSec = 0.13        // trail the head by ~1.3 tap chunks so we never starve mid-chunk
    private let minLagSec = 0.012    // never read closer than this to the head (a half-filled chunk edge)
    private let maxLagSec = 0.30     // fell this far behind (stall/seek) ⇒ resync to the nominal lag

    /// Absolute end-frame to read a window up to, given the ring's monotonic `head` (= frames written).
    func endFrame(now: Double, head: Int, sampleRate: Double) -> Int {
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let target = Double(head) - lagSec * sr
        guard seeded else { seeded = true; lastNow = now; pos = max(0, target); return Int(pos) }
        let dt = min(max(0, now - lastNow), 0.05)
        lastNow = now
        pos += dt * sr
        let ceil = Double(head) - minLagSec * sr
        if pos > ceil { pos = ceil }                                  // caught the head → hold (no future data)
        if pos < Double(head) - maxLagSec * sr { pos = target }       // stall/seek ⇒ resync
        if pos < 0 { pos = 0 }
        return Int(pos)
    }
}
