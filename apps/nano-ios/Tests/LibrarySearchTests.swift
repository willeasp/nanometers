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
}
