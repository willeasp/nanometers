import XCTest
import AVFoundation
@testable import NanoMeters

final class PlaybackMathTests: XCTestCase {
    func test_fractionMidpoint() {
        XCTAssertEqual(PlaybackMath.fraction(frame: 50, total: 100), 0.5, accuracy: 1e-9)
    }
    func test_fractionGuardsZeroTotal() {
        XCTAssertEqual(PlaybackMath.fraction(frame: 10, total: 0), 0)
    }
    func test_fractionClampsOverrun() {
        XCTAssertEqual(PlaybackMath.fraction(frame: 150, total: 100), 1)
        XCTAssertEqual(PlaybackMath.fraction(frame: -5, total: 100), 0)
    }
    func test_clockFormatsMinutesSeconds() {
        XCTAssertEqual(PlaybackMath.clock(0), "0:00")
        XCTAssertEqual(PlaybackMath.clock(9), "0:09")
        XCTAssertEqual(PlaybackMath.clock(75), "1:15")
        XCTAssertEqual(PlaybackMath.clock(-3), "0:00")
    }
}
