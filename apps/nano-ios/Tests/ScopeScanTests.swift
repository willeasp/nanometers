import XCTest
@testable import NanoMeters

/// Deterministic guard for the goniometer's smooth-scan. The audio tap delivers ~100 ms chunks (~10 Hz),
/// so a meter that reads "the newest N frames" only changes 10×/s and stutters. `ScopeCursor` advances a
/// read position by real elapsed time and trails the write head, turning chunky delivery into a fresh,
/// monotonically-advancing window every display frame. (A screenshot UI test can't measure this — XCUITest
/// throttles captures below 10 Hz and doesn't render audio at real-time — so it's verified here instead.)
final class ScopeScanTests: XCTestCase {
    private let sr = 48_000.0

    private func feed(_ tap: LiveScopeTap, frames: Int, phase: Int) {
        var l = [Float](repeating: 0, count: frames)
        var r = [Float](repeating: 0, count: frames)
        for i in 0..<frames { let v = Float((phase + i) % 997) / 997; l[i] = v; r[i] = -v }
        l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                tap.feed(left: lp.baseAddress!, right: rp.baseAddress!, frames: frames, sampleRate: sr)
            }
        }
    }

    /// Feeding in 10 Hz chunks while ticking the cursor at 60 Hz wall-clock must yield a distinct,
    /// forward-only window almost every tick — i.e. the goniometer animates at display rate, not 10 Hz.
    func test_cursorScansChunkyFeedAtDisplayRate() {
        let tap = LiveScopeTap()
        let cursor = ScopeCursor()
        let chunk = 4800                      // 0.1 s @ 48k → 10 Hz delivery
        var fed = 0
        feed(tap, frames: chunk, phase: fed); fed += chunk     // prime some history
        feed(tap, frames: chunk, phase: fed); fed += chunk

        var ends = Set<Int>()
        var lastEnd = -1
        var monotonic = true
        var now = 1000.0
        for tick in 0..<60 {                                   // ~1 s of 60 Hz ticks
            if tick % 6 == 0 { feed(tap, frames: chunk, phase: fed); fed += chunk }   // a chunk every 0.1 s
            now += 1.0 / 60.0
            let end = cursor.endFrame(now: now, head: tap.written, sampleRate: sr)
            if end < lastEnd { monotonic = false }
            lastEnd = end
            ends.insert(end)
        }
        XCTAssertTrue(monotonic, "cursor must advance forward-only (no backward jumps)")
        XCTAssertGreaterThanOrEqual(ends.count, 50,
            "cursor stalled — only \(ends.count) distinct windows in 60 ticks; the goniometer would stutter")
    }

    /// `window(endingAt:count:)` returns the requested absolute range oldest→newest, and reads 0 for
    /// frames that have already scrolled out of the ring.
    func test_windowReadsAbsoluteRangeAndZeroPadsEvicted() {
        let tap = LiveScopeTap(capacity: 1024)
        feed(tap, frames: 2000, phase: 0)                      // wraps the 1024 ring; total = 2000
        XCTAssertEqual(tap.written, 2000)

        let newest = tap.window(endingAt: 2000, count: 4)      // abs 1996…1999
        let expected = [1996, 1997, 1998, 1999].map { Float($0 % 997) / 997 }
        XCTAssertEqual(newest.l, expected)
        XCTAssertEqual(newest.r, expected.map { -$0 })         // r == -l as fed

        let evicted = tap.window(endingAt: 500, count: 4)      // abs 496…499 < oldest (976) → zeros
        XCTAssertEqual(evicted.l, [0, 0, 0, 0])
    }

    /// A reset zeroes the absolute clock too, so the cursor re-seeds instead of reading a stale mapping.
    func test_resetZeroesClock() {
        let tap = LiveScopeTap()
        feed(tap, frames: 4800, phase: 0)
        XCTAssertGreaterThan(tap.written, 0)
        tap.reset()
        XCTAssertEqual(tap.written, 0)
        XCTAssertTrue(tap.window(endingAt: 0, count: 8).l.isEmpty, "no buffered frames after reset")
    }
}
