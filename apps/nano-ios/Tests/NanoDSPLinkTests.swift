import XCTest
@testable import NanoMeters

final class NanoDSPLinkTests: XCTestCase {
    func test_bridgeAnalyzesAndMeasuresASynthTone() {
        let sr = 48_000.0
        let n = Int(sr * 4.0)
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { mono[i] = 0.5 * sinf(2.0 * .pi * 1000.0 * Float(i) / Float(sr)) }

        let bins = NanoDSPBridge.analyze(mono: mono, sampleRate: sr, binCount: 150)
        XCTAssertNotNil(bins, "analyze returned nil (link or rc failure)")
        XCTAssertEqual(bins?.count, 150)
        XCTAssertTrue(bins?.allSatisfy { $0.peak >= 0 && $0.peak <= 1 } ?? false, "peaks not normalized 0…1")
        XCTAssertTrue(bins?.contains { $0.peak > 0.5 } ?? false, "no loud bin found")

        let lufs = NanoDSPBridge.integratedLUFS(l: mono, r: mono, sampleRate: sr)
        XCTAssertNotNil(lufs)
        XCTAssertTrue((lufs ?? 0) > -30 && (lufs ?? 0) < 0, "integrated LUFS implausible: \(String(describing: lufs))")
    }

    func test_bridgeAnalyzesStereoEnvelopes() {
        let sr = 48_000.0
        let n = Int(sr * 2.0)
        var l = [Float](repeating: 0, count: n)
        var r = [Float](repeating: 0, count: n)
        for i in 0..<n {
            l[i] = 0.5 * sinf(2.0 * .pi * 1000.0 * Float(i) / Float(sr))
            r[i] = l[i]
        }
        let bins = NanoDSPBridge.analyzeStereo(l: l, r: r, sampleRate: sr, binCount: 400)
        XCTAssertNotNil(bins, "analyzeStereo returned nil (link or rc failure)")
        XCTAssertEqual(bins?.count, 400)
        XCTAssertTrue(bins?.allSatisfy {
            (-1...1).contains($0.lMin) && (-1...1).contains($0.lMax)
                && (-1...1).contains($0.rMin) && (-1...1).contains($0.rMax)
        } ?? false, "envelopes normalized -1…1")
        XCTAssertTrue(bins?.contains { $0.lMax > 0.5 && $0.lMin < -0.5 } ?? false, "loud tone fills the contour")
        // L == R for identical channels.
        XCTAssertTrue(bins?.allSatisfy { abs($0.lMax - $0.rMax) < 1e-6 } ?? false, "L == R for L=R input")
    }

    func test_liveScopeTapRingReturnsNewestFrames() {
        let tap = LiveScopeTap(capacity: 1024)
        // Feed a ramp so each frame is identifiable; overflow the ring to exercise wrap-around.
        var l = (0..<3000).map { Float($0) }
        let r = l
        l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                tap.feed(left: lp.baseAddress!, right: rp.baseAddress!, frames: l.count, sampleRate: 48_000)
            }
        }
        let snap = tap.snapshot(512)
        XCTAssertEqual(snap.l.count, 512, "ring caps at capacity, returns the requested newest count")
        XCTAssertEqual(snap.sampleRate, 48_000)
        // Oldest→newest, ending at the last fed value (2999).
        XCTAssertEqual(snap.l.last, 2999)
        XCTAssertEqual(snap.l.first, 2999 - 511)
        XCTAssertEqual(snap.l, snap.r)
        tap.reset()
        XCTAssertEqual(tap.snapshot(512).l.count, 0, "reset empties the ring")
    }

    func test_liveMeterReadsMomentaryFromATone() {
        let sr = 48_000.0
        let n = Int(sr * 4.0)                                   // ~4 s → the 400 ms momentary window fills
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
        XCTAssertNotNil(last, "no momentary reading after ~4 s of tone (link or wiring failure)")
        XCTAssertTrue((last ?? 0) > -40 && (last ?? 0) < 0,
                      "momentary implausible: \(String(describing: last))")
    }
}
