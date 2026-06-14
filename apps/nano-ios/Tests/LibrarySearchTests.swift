import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibrarySearchTests: XCTestCase {
    /// gdrive root "mine" → House[Caldera by Oso], DnB[Strata by Oso]; All reachable.
    private func fixture() throws -> (ModelContext, LibraryIndex) {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "mine"))
        func t(_ title: String, _ artist: String, _ folder: String) -> UUID {
            let tr = Track(title: title, artist: artist, album: ""); tr.sourceId = "gdrive"; tr.folderId = folder
            ctx.insert(tr); return tr.id
        }
        let c = t("Caldera", "Oso", "house"); let s = t("Strata", "Oso", "dnb")
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "My Productions", parentId: nil, childFolderIds: ["house","dnb"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [c]))
        ctx.insert(FolderNode(id: "dnb", sourceId: "gdrive", name: "Drum & Bass", parentId: "mine", trackIds: [s]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        return (ctx, idx)
    }

    func test_search_recursesScope_caseInsensitive_titleArtist() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive")              // scope = whole Drive
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        let hits = LibraryBrowse.search(scope, query: "calder", nav: n, index: idx, ctx: ctx)
        XCTAssertEqual(hits.map(\.track.title), ["Caldera"])
        XCTAssertEqual(hits.first?.pathLabel, "My Productions / House")   // folder path under source
    }

    func test_search_inLeafFolder_onlyThatSubtree() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine"); n.openFolder("dnb")
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        XCTAssertEqual(LibraryBrowse.search(scope, query: "oso", nav: n, index: idx, ctx: ctx).map(\.track.title), ["Strata"])
    }

    func test_search_allSongs_pathHasSourceShortPrefix() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openAllSongs()
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        let hits = LibraryBrowse.search(scope, query: "strata", nav: n, index: idx, ctx: ctx)
        XCTAssertEqual(hits.first?.pathLabel, "Drive / My Productions / Drum & Bass")  // §04: full source path
    }

    func test_search_emptyQuery_noHits() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openAllSongs()
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        XCTAssertTrue(LibraryBrowse.search(scope, query: "  ", nav: n, index: idx, ctx: ctx).isEmpty)
    }

    // MARK: - Bug A regression tests

    /// A track id present in TWO sibling folders → search returns ONE hit for it, playAll contains it once.
    func test_dedupeByID_trackInTwoFolders_searchReturnsOneHit_playAllContainsOnce() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "Root", providerFolderId: "root"))
        // Insert one track and register it in TWO sibling folders (simulates DAG or multi-folder tagging).
        let tr = Track(title: "Shared", artist: "Oso", album: ""); tr.sourceId = "gdrive"; tr.folderId = "folderA"
        ctx.insert(tr)
        ctx.insert(FolderNode(id: "root",    sourceId: "gdrive", name: "Root",    parentId: nil,    childFolderIds: ["folderA","folderB"]))
        ctx.insert(FolderNode(id: "folderA", sourceId: "gdrive", name: "FolderA", parentId: "root", trackIds: [tr.id]))
        ctx.insert(FolderNode(id: "folderB", sourceId: "gdrive", name: "FolderB", parentId: "root", trackIds: [tr.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)

        let n = LibraryNav(); n.openSource("gdrive")
        let content = LibraryBrowse.content(for: n, index: idx, ctx: ctx)

        // playAll must contain the track exactly once
        XCTAssertEqual(content.playAll.filter { $0.id == tr.id }.count, 1, "playAll should dedupe cross-folder tracks")

        // search must return exactly one hit
        let hits = LibraryBrowse.search(content.playAll, query: "shared", nav: n, index: idx, ctx: ctx)
        XCTAssertEqual(hits.count, 1, "search should return one hit even when track appears in two folders")
        XCTAssertEqual(hits.first?.track.id, tr.id)
    }

    // MARK: - Bug C regression tests

    /// Scope = a deep folder → the hit's pathLabel is the path BELOW the scope (or "" if directly in scope folder).
    func test_relativePath_deepScope_stripsPrefix() throws {
        let (ctx, idx) = try fixture()
        // Scope = the "house" folder directly (which holds "Caldera")
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine"); n.openFolder("house")
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        let hits = LibraryBrowse.search(scope, query: "caldera", nav: n, index: idx, ctx: ctx)
        XCTAssertEqual(hits.count, 1)
        // "Caldera" is directly in "house" (the scope folder), so after stripping ["mine","house"] the relative path is ""
        XCTAssertEqual(hits.first?.pathLabel, "", "pathLabel should be empty when the hit is directly in the scope folder")
    }

    /// Scope = source root (nav.folderIds == []) → pathLabel includes the full path from the root.
    func test_relativePath_sourceRoot_includesFullPath() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive")  // folderIds == []
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        let hits = LibraryBrowse.search(scope, query: "caldera", nav: n, index: idx, ctx: ctx)
        XCTAssertEqual(hits.first?.pathLabel, "My Productions / House",
                       "at source root (no scope prefix) the full folder path should be shown")
    }
}
