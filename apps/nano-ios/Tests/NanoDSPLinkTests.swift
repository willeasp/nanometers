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
}
