import XCTest
@testable import NanoMeters

@MainActor
final class LibraryNavTests: XCTestCase {
    func test_root_isDefault() {
        let n = LibraryNav()
        XCTAssertNil(n.smart); XCTAssertNil(n.sourceId); XCTAssertEqual(n.folderIds, [])
        XCTAssertTrue(n.isRoot)
    }
    func test_openSource_thenFolders_thenUp() {
        let n = LibraryNav()
        n.openSource("gdrive")
        XCTAssertEqual(n.sourceId, "gdrive"); XCTAssertEqual(n.folderIds, []); XCTAssertFalse(n.isRoot)
        n.openFolder("mine"); n.openFolder("house")
        XCTAssertEqual(n.folderIds, ["mine", "house"])
        n.up(); XCTAssertEqual(n.folderIds, ["mine"])
        n.up(); XCTAssertEqual(n.folderIds, [])           // at source root
        n.up(); XCTAssertTrue(n.isRoot)                   // pops to Library root
    }
    func test_jumpTo_breadcrumbAncestor() {
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine"); n.openFolder("house")
        n.jumpTo(folderDepth: 1)                          // keep first folder only
        XCTAssertEqual(n.folderIds, ["mine"])
        n.jumpTo(folderDepth: 0)                          // source root
        XCTAssertEqual(n.folderIds, [])
    }
    func test_openAllSongs_andReset() {
        let n = LibraryNav(); n.openSource("gdrive")
        n.openAllSongs()
        XCTAssertEqual(n.smart, .allSongs); XCTAssertNil(n.sourceId)
        n.reset(); XCTAssertTrue(n.isRoot); XCTAssertNil(n.smart)
    }
    func test_goToSource_setsSourceAndPath() {
        let n = LibraryNav()
        n.goToSource(sourceId: "gdrive", folderIds: ["mine", "house"])
        XCTAssertEqual(n.sourceId, "gdrive"); XCTAssertEqual(n.folderIds, ["mine", "house"])
        XCTAssertNil(n.smart)
    }
}
