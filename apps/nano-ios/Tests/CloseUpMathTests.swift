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
}
