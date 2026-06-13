import XCTest
@testable import NanoMeters

final class SourceKindTests: XCTestCase {
    func test_canonicalOrder_isLocalFirst_thenICloudThenDrive() {
        XCTAssertEqual(SourceKind.local.canonicalOrder, 0)
        XCTAssertEqual(SourceKind.icloud.canonicalOrder, 1)
        XCTAssertEqual(SourceKind.gdrive.canonicalOrder, 2)
        XCTAssertLessThan(SourceKind.gdrive.canonicalOrder, SourceKind.dropbox.canonicalOrder)
    }

    func test_tintHex_matchesHandoffPalette() {
        XCTAssertEqual(SourceKind.local.tintHex, "#B990F5")
        XCTAssertEqual(SourceKind.gdrive.tintHex, "#6FCF72")
    }

    func test_short_isAbbreviated() {
        XCTAssertEqual(SourceKind.gdrive.short, "Drive")
        XCTAssertEqual(SourceKind.local.short, "iPhone")
    }

    func test_sourceState_roundTripsRawValue() {
        XCTAssertEqual(SourceState(rawValue: "connected"), .connected)
        XCTAssertEqual(SourceState.needsReauth.rawValue, "needsReauth")
    }
}
