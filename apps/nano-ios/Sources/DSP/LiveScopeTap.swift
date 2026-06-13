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
        var rate: Double = 0
    }
    private let lock: OSAllocatedUnfairLock<State>

    /// Capacity ≥ the largest read window (spectrum FFT ~2048 + goniometer ~1024, with slack).
    init(capacity: Int = 8192) {
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

    /// Drop buffered history (call on track change / seek). Cheap; any thread.
    func reset() { lock.withLock { st in st.count = 0; st.head = 0 } }
}
