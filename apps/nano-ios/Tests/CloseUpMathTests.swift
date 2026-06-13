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

    /// The scroll must glide forward even when the audio clock arrives as a coarse staircase (the real
    /// cause of the "low FPS" look). The subway-sign model advances a frame-counted, reservoir-controlled
    /// step per tick: it must NEVER step backward (no jitter) and must track ~real time within the small
    /// reservoir latency.
    func test_scrollClockGlidesForwardDespiteStaircasedAudio() {
        let clock = ScrollClock()
        var prev = -1.0
        var maxBackstep = 0.0
        var lastAudio = 0.0
        for i in 0..<120 {                                          // 2 s of 60 Hz frames
            let now = Double(i)                                     // frame token (distinct per frame)
            lastAudio = Double(Int(Double(i) / 60.0 / 0.085)) * 0.085   // audio updates only every ~85 ms
            let c = clock.present(now: now, audio: lastAudio, playing: true)
            if prev >= 0 { maxBackstep = max(maxBackstep, prev - c) }
            prev = c
        }
        XCTAssertLessThan(maxBackstep, 0.0005, "scroll stepped backward (\(maxBackstep)s) — would read as jitter")
        XCTAssertEqual(prev, lastAudio, accuracy: 0.15, "should track real time within the reservoir latency")
    }

    /// Regression for the slow-start: priming the rate means the scroll advances on the FIRST frame after
    /// a (re)seed instead of freezing for ~50 ms while the rate EMA warms up from zero.
    func test_scrollClockStartsMovingImmediatelyAfterSeed() {
        let clock = ScrollClock()
        _ = clock.present(now: 0, audio: 0, playing: true)             // seed frame (holds at audio)
        let first = clock.present(now: 1, audio: 0, playing: true)     // first real frame, audio not yet ticked
        XCTAssertGreaterThan(first, 0, "scroll must advance on the first frame after seed, not freeze")
    }

    /// A re-render between vsync ticks (same frame date) must NOT advance the scroll — only genuine new
    /// frames do — so parent invalidations can't make the playhead race.
    func test_scrollClockHoldsWithinTheSameFrame() {
        let clock = ScrollClock()
        _ = clock.present(now: 0, audio: 0, playing: true)
        _ = clock.present(now: 1, audio: 0.2, playing: true)
        let a = clock.present(now: 2, audio: 0.4, playing: true)
        let b = clock.present(now: 2, audio: 0.4, playing: true)   // same frame date → must not advance
        XCTAssertEqual(a, b, accuracy: 1e-12, "same-tick re-render advanced the scroll")
    }

    func test_scrollClockSnapsOnSeekAndHoldsWhenPaused() {
        let clock = ScrollClock()
        _ = clock.present(now: 0, audio: 0, playing: true)
        _ = clock.present(now: 1, audio: 0.2, playing: true)
        // A big discontinuity (scrub) must snap, not crawl across the gap.
        XCTAssertEqual(clock.present(now: 2, audio: 30, playing: true), 30, accuracy: 0.001, "seek should snap")
        // Paused returns the (held) audio position verbatim — re-centers on a paused scrub.
        XCTAssertEqual(clock.present(now: 3, audio: 12, playing: false), 12, accuracy: 0.001, "pause should hold")
    }
}
