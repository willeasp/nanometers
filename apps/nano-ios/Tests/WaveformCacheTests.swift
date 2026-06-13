import XCTest
@testable import NanoMeters

final class WaveformCacheTests: XCTestCase {
    func test_roundTripsBinsAndLUFS() throws {
        let key = "test_\(UUID().uuidString)"
        defer { WaveformCache.remove(key: key) }
        let bins = (0..<40).map { WaveBin(peak: Float($0) / 40, r: 0.2, g: 0.5, b: 0.8) }
        let closeUp = (0..<200).map {
            StereoWaveBin(lMin: -Float($0) / 200, lMax: Float($0) / 200,
                          rMin: -Float($0) / 220, rMax: Float($0) / 210, r: 0.9, g: 0.3, b: 0.1)
        }
        WaveformCache.save(key: key, bins: bins, closeUpBins: closeUp,
                           integratedLUFS: -9.5, sampleRate: 44_100, durationSec: 4.0)

        let loaded = WaveformCache.load(key: key)
        XCTAssertEqual(loaded?.bins, bins)
        XCTAssertEqual(loaded?.closeUpBins, closeUp)        // v2: stereo close-up array round-trips
        XCTAssertEqual(loaded?.integratedLUFS, -9.5)
    }

    func test_missReturnsNil() {
        XCTAssertNil(WaveformCache.load(key: "definitely-not-present-\(UUID().uuidString)"))
    }

    /// A v1 (mono-only) file must be rejected by the version check so it re-analyzes into v2 — no
    /// silent half-load. Simulate by writing the old "NMW1"/version-1 header.
    func test_v1FileRejectedAsCacheMiss() throws {
        let key = "v1_\(UUID().uuidString)"
        let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("\(key).nmwave")
        defer { try? FileManager.default.removeItem(at: file) }
        var data = Data()
        func put<T>(_ v: T) { var v = v; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        put(UInt32(0x314D574E).littleEndian)   // "NMW1"
        put(UInt16(1).littleEndian)            // version 1
        put(Float(44_100).bitPattern.littleEndian)
        put(Double(4.0).bitPattern.littleEndian)
        put((-9.5).bitPattern.littleEndian)
        put(UInt32(0).littleEndian)            // 0 mono bins
        try data.write(to: file, options: .atomic)

        XCTAssertNil(WaveformCache.load(key: key), "v1 file must be a cache miss → re-analyze")
    }
}
