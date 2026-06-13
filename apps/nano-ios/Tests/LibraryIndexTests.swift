import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibraryIndexTests: XCTestCase {
    /// Build: gdrive (connected) → root "My Productions" [house(2 tracks), dnb(1 track)]; local disconnected.
    private func fixture() throws -> (ModelContext, [String: Track]) {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(Source(id: "local", kind: .local, state: .disconnected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "mine"))
        ctx.insert(RootFolder(sourceId: "local", name: "Old", bookmark: Data([9])))

        var tracks: [String: Track] = [:]
        func mk(_ key: String, folder: String) -> UUID {
            let t = Track(title: key, artist: "", album: "")
            t.sourceId = "gdrive"; t.folderId = folder
            ctx.insert(t); tracks[key] = t; return t.id
        }
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "My Productions",
                              parentId: nil, childFolderIds: ["house", "dnb"]))
        let h1 = mk("h1", folder: "house"); let h2 = mk("h2", folder: "house")
        let d1 = mk("d1", folder: "dnb")
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [h1, h2]))
        ctx.insert(FolderNode(id: "dnb", sourceId: "gdrive", name: "Drum & Bass", parentId: "mine", trackIds: [d1]))
        // A local track under the DISCONNECTED source — must NOT be reachable.
        let lt = Track(title: "old", artist: "", album: ""); lt.sourceId = "local"; lt.folderId = "old"
        ctx.insert(lt); tracks["old"] = lt
        ctx.insert(FolderNode(id: "old", sourceId: "local", name: "Old", parentId: nil, trackIds: [lt.id]))
        return (ctx, tracks)
    }

    func test_reachable_excludesDisconnectedSources() throws {
        let (ctx, t) = try fixture()
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertTrue(idx.reachableTrackIds.contains(t["h1"]!.id))
        XCTAssertFalse(idx.reachableTrackIds.contains(t["old"]!.id))   // disconnected source
        XCTAssertEqual(idx.reachableTrackIds.count, 3)
    }

    func test_recursiveCounts() throws {
        let (ctx, _) = try fixture()
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertEqual(idx.folderCounts["mine"]?.folders, 2)
        XCTAssertEqual(idx.folderCounts["mine"]?.tracks, 3)   // recursive
        XCTAssertEqual(idx.folderCounts["house"]?.tracks, 2)
        XCTAssertEqual(idx.sourceCounts["gdrive"]?.tracks, 3)
        XCTAssertEqual(idx.sourceCounts["gdrive"]?.folders, 3) // root + 2 children
    }

    func test_pathForGoToSource() throws {
        let (ctx, t) = try fixture()
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        let p = idx.trackPath[t["h1"]!.id]
        XCTAssertEqual(p?.sourceId, "gdrive")
        XCTAssertEqual(p?.folderIds, ["mine", "house"])   // root → leaf
    }
}
