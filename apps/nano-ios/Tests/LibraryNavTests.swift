import XCTest
import SwiftData
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

    func test_goToSource_resolvesPath_setsHighlight_andRequestsLibrary() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "P", providerFolderId: "mine"))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"
        ctx.insert(tr)
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "P", parentId: nil, childFolderIds: ["house"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [tr.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        let n = LibraryNav()
        let before = n.switchToLibraryToken
        let ok = n.goToSource(track: tr, index: idx, ctx: ctx)
        XCTAssertTrue(ok)
        XCTAssertEqual(n.sourceId, "gdrive"); XCTAssertEqual(n.folderIds, ["mine", "house"])
        XCTAssertEqual(n.highlightTrackId, tr.id)
        XCTAssertGreaterThan(n.switchToLibraryToken, before)
    }
    func test_goToSource_disconnectedSource_returnsFalse_noNav() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .disconnected))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"; ctx.insert(tr)
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        let n = LibraryNav()
        XCTAssertFalse(n.goToSource(track: tr, index: idx, ctx: ctx))
        XCTAssertNil(n.sourceId)
    }
}
