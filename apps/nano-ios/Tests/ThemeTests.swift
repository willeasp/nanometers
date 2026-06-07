import XCTest
import SwiftUI
@testable import NanoMeters

final class ThemeTests: XCTestCase {
    func test_accentHexParses() {
        // The locked accent is #EFA869 (handoff §01). A round-trip through the hex initializer
        // must reproduce those 8-bit channels.
        let c = UIColor(Theme.accent).cgColor.components!
        XCTAssertEqual(c[0], 0xEF / 255, accuracy: 0.01)
        XCTAssertEqual(c[1], 0xA8 / 255, accuracy: 0.01)
        XCTAssertEqual(c[2], 0x69 / 255, accuracy: 0.01)
    }
    func test_colorFromHexStringMatchesIntLiteral() {
        XCTAssertEqual(Color(hex: "#14161C"), Color(hex: 0x14161C))
        XCTAssertEqual(Color(hex: "111319"), Color(hex: 0x111319))   // leading # optional
    }
    func test_colorFromBadHexFallsBackToClear() {
        XCTAssertEqual(Color(hex: "nope"), Color.clear)
    }
}
