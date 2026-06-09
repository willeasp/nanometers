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
}
