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

    // MARK: - Bug B regression: highlight clear is owned by goToSource, not the view

    /// goToSource sets highlightTrackId immediately; the self-owned Task clears it after ~2.8s.
    /// This test only verifies the synchronous side (set + token bump); timer behaviour is not unit-testable.
    func test_goToSource_setsHighlight_andOwnsTheClear() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "P", providerFolderId: "mine"))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"; ctx.insert(tr)
        ctx.insert(FolderNode(id: "mine",  sourceId: "gdrive", name: "P",     parentId: nil,    childFolderIds: ["house"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [tr.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        let n = LibraryNav()
        XCTAssertTrue(n.goToSource(track: tr, index: idx, ctx: ctx))
        // highlight must be set synchronously by goToSource, not by the view
        XCTAssertEqual(n.highlightTrackId, tr.id)
    }

    // MARK: - Bug E regression: only .connected and .offline are reachable

    func test_goToSource_needsReauth_returnsFalse() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .needsReauth))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"; ctx.insert(tr)
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: nil, trackIds: [tr.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertFalse(LibraryNav().goToSource(track: tr, index: idx, ctx: ctx),
                       "needsReauth should not be treated as reachable")
    }

    func test_goToSource_authorizing_returnsFalse() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .authorizing))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"; ctx.insert(tr)
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: nil, trackIds: [tr.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertFalse(LibraryNav().goToSource(track: tr, index: idx, ctx: ctx),
                       "authorizing should not be treated as reachable")
    }

    func test_goToSource_offline_returnsTrue() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .offline))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "P", providerFolderId: "mine"))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"; ctx.insert(tr)
        ctx.insert(FolderNode(id: "mine",  sourceId: "gdrive", name: "P",     parentId: nil,    childFolderIds: ["house"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [tr.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertTrue(LibraryNav().goToSource(track: tr, index: idx, ctx: ctx),
                      "offline source should be reachable for Go-to-Source")
    }
}
