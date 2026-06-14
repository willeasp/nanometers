import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibraryBrowseTests: XCTestCase {
    /// gdrive(connected, root "mine"→house[2]) + local(connected, root "local-root"[1]) + dropbox(disconnected)
    private func fixture() throws -> (ModelContext, LibraryIndex) {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "local", kind: .local, state: .connected))
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(Source(id: "dropbox", kind: .dropbox, state: .disconnected))
        ctx.insert(RootFolder(sourceId: "local", name: "On My iPhone", nodeId: "local-root"))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "mine"))
        func t(_ title: String, _ folder: String) -> UUID {
            let tr = Track(title: title, artist: "", album: ""); tr.sourceId = folder == "local-root" ? "local" : "gdrive"; tr.folderId = folder
            ctx.insert(tr); return tr.id
        }
        let l1 = t("local1", "local-root")
        let h1 = t("h1", "house"); let h2 = t("h2", "house")
        ctx.insert(FolderNode(id: "local-root", sourceId: "local", name: "On My iPhone", parentId: nil, trackIds: [l1]))
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "My Productions", parentId: nil, childFolderIds: ["house"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [h1, h2]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        return (ctx, idx)
    }

    func test_root_listsAllSongs_andConnectedSources_inCanonicalOrder_excludingDisconnected() throws {
        let (ctx, idx) = try fixture()
        let c = LibraryBrowse.content(for: LibraryNav(), index: idx, ctx: ctx)
        XCTAssertEqual(c.level, .root)
        XCTAssertEqual(c.allSongsCount, 3)                      // reachable only (dropbox excluded)
        XCTAssertEqual(c.sources.map(\.id), ["local", "gdrive"]) // canonical order, dropbox hidden
    }

    func test_sourceRoot_showsRootFolders_andBreadcrumb() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive")
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.level, .folder)
        XCTAssertEqual(c.title, "Google Drive")               // source root title = source label
        // At a source root we show the source's root folders as the "folders" list:
        XCTAssertEqual(c.folders.map(\.name), ["My Productions"])
        XCTAssertEqual(c.crumbs.first?.label, "Drive")         // first crumb = source short name
    }

    func test_insideFolder_showsSubfoldersTracks_breadcrumb_andRecursivePlayAll() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine")
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.title, "My Productions")
        XCTAssertEqual(c.folders.map(\.name), ["House"])   // sub-folder
        XCTAssertEqual(c.tracks.count, 0)                  // "mine" has no direct tracks
        XCTAssertEqual(c.playAll.map(\.title).sorted(), ["h1", "h2"])  // recursive into House
        XCTAssertEqual(c.crumbs.map(\.label), ["Drive", "My Productions"])
    }

    func test_leafFolder_directTracks_playAllEqualsTracks() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine"); n.openFolder("house")
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.folders.count, 0)
        XCTAssertEqual(c.tracks.map(\.title).sorted(), ["h1", "h2"])
        XCTAssertEqual(c.playAll.count, 2)
    }

    func test_allSongs_flatReachableTracks() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openAllSongs()
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.level, .allSongs)
        XCTAssertEqual(c.title, "All Songs")
        XCTAssertEqual(Set(c.tracks.map(\.title)), ["local1", "h1", "h2"])   // reachable only
        XCTAssertEqual(c.playAll.count, 3)
    }

    // MARK: - isAvailable (FIX 1)

    func test_isAvailable_bundledTrack_availableEvenWhenNotReachable() throws {
        let ctx = try TestDB.context()
        // A bundled track has no sourceId / index presence — it lives in the app bundle.
        let t = Track(title: "Demo", artist: "", album: "", bundledName: "demo.mp3")
        ctx.insert(t)
        let idx = LibraryIndex(); idx.rebuild(from: ctx)   // empty index; no sources
        XCTAssertTrue(LibraryBrowse.isAvailable(t, index: idx),
                      "Bundled track must be available regardless of index state")
    }

    func test_isAvailable_localBookmarkTrack_availableEvenWhenNotReachable() throws {
        let ctx = try TestDB.context()
        let t = Track(title: "Local", artist: "", album: "", bookmark: Data([0xDE, 0xAD]))
        ctx.insert(t)
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertTrue(LibraryBrowse.isAvailable(t, index: idx),
                      "Track with a file bookmark must be available regardless of index state")
    }

    func test_isAvailable_cloudTrack_disconnectedSource_unavailable() throws {
        let ctx = try TestDB.context()
        // A cloud track whose source was disconnected: source row deleted, node deleted, track row kept.
        let t = Track(title: "Cloud", artist: "", album: "")
        t.sourceId = "gdrive"
        t.providerFileId = "file-123"
        // No source row, no folder nodes — index is empty.
        ctx.insert(t)
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertFalse(LibraryBrowse.isAvailable(t, index: idx),
                       "Cloud track with no reachable source must be unavailable")
    }

    func test_isAvailable_cloudTrack_connectedSource_available() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "Mine", providerFolderId: "root"))
        let t = Track(title: "Cloud", artist: "", album: "")
        t.sourceId = "gdrive"; t.providerFileId = "file-123"
        ctx.insert(t)
        ctx.insert(FolderNode(id: "root", sourceId: "gdrive", name: "Mine", parentId: nil, trackIds: [t.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertTrue(LibraryBrowse.isAvailable(t, index: idx),
                      "Cloud track under a connected source must be available")
    }
}
