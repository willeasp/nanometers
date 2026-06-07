import XCTest
@testable import NanoMeters

final class WaveformCacheTests: XCTestCase {
    func test_roundTripsBinsAndLUFS() throws {
        let key = "test_\(UUID().uuidString)"
        defer { WaveformCache.remove(key: key) }
        let bins = (0..<40).map { WaveBin(peak: Float($0) / 40, r: 0.2, g: 0.5, b: 0.8) }
        WaveformCache.save(key: key, bins: bins, integratedLUFS: -9.5, sampleRate: 44_100, durationSec: 4.0)

        let loaded = WaveformCache.load(key: key)
        XCTAssertEqual(loaded?.bins, bins)
        XCTAssertEqual(loaded?.integratedLUFS, -9.5)
    }

    func test_missReturnsNil() {
        XCTAssertNil(WaveformCache.load(key: "definitely-not-present-\(UUID().uuidString)"))
    }
}
