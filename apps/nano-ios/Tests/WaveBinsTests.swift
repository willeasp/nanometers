import XCTest
@testable import NanoMeters

final class WaveBinsTests: XCTestCase {
    func test_maxDownsampleKeepsPeakOfEachRange() {
        let bins = (0..<100).map { WaveBin(peak: Float($0) / 100, r: 0, g: 0, b: 0) }
        let out = WaveBins.maxDownsample(bins, to: 10)
        XCTAssertEqual(out.count, 10)
        XCTAssertEqual(out.last?.peak ?? 0, 0.99, accuracy: 0.001)
        XCTAssertTrue(zip(out, out.dropFirst()).allSatisfy { $0.peak <= $1.peak }, "monotone for a ramp")
    }
    func test_downsampleHandlesFewerSourceBins() {
        let bins = [WaveBin(peak: 0.4, r: 0, g: 0, b: 0)]
        XCTAssertEqual(WaveBins.maxDownsample(bins, to: 22).count, 22)
    }
}
