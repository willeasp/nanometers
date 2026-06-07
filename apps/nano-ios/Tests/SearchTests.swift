import XCTest
@testable import NanoMeters

final class SearchTests: XCTestCase {
    private func mk(_ t: String, _ a: String, _ al: String) -> Track { Track(title: t, artist: a, album: al) }

    func test_filterMatchesTitleArtistAlbumCaseInsensitive() {
        let lib = [mk("Midnight Drive", "Aurora", "Neon"), mk("Glass Harbor", "Aurora", "Neon"), mk("Sketch", "you", "Demos")]
        XCTAssertEqual(SearchFilter.match(lib, query: "aur").count, 2)     // artist, case-insensitive
        XCTAssertEqual(SearchFilter.match(lib, query: "harbor").map(\.title), ["Glass Harbor"]) // title
        XCTAssertEqual(SearchFilter.match(lib, query: "demos").count, 1)   // album
        XCTAssertEqual(SearchFilter.match(lib, query: "").count, 3)        // empty → all
    }
}
