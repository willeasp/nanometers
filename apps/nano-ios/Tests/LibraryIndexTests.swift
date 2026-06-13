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

    // MARK: - New regression tests

    func test_twoLocalRoots_bothReachable_countedOnce() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "local", kind: .local, state: .connected))

        let tA = Track(title: "A", artist: "", album: ""); ctx.insert(tA)
        let tB = Track(title: "B", artist: "", album: ""); ctx.insert(tB)

        ctx.insert(FolderNode(id: "ra", sourceId: "local", name: "Root A", parentId: nil, trackIds: [tA.id]))
        ctx.insert(FolderNode(id: "rb", sourceId: "local", name: "Root B", parentId: nil, trackIds: [tB.id]))

        ctx.insert(RootFolder(sourceId: "local", name: "Root A", nodeId: "ra"))
        ctx.insert(RootFolder(sourceId: "local", name: "Root B", nodeId: "rb"))

        let idx = LibraryIndex(); idx.rebuild(from: ctx)

        XCTAssertEqual(idx.reachableTrackIds.count, 2)
        XCTAssertEqual(idx.sourceCounts["local"]?.tracks, 2)
        // Each root node counts as 1 folder (0 descendants each), so total folders = 1+1 = 2
        XCTAssertEqual(idx.sourceCounts["local"]?.folders, 2)
        XCTAssertNotNil(idx.folderCounts["ra"])
        XCTAssertNotNil(idx.folderCounts["rb"])
    }

    func test_reachable_includesOfflineAndNeedsReauth_excludesDisconnected() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "src-offline",     kind: .gdrive,  state: .offline))
        ctx.insert(Source(id: "src-reauth",      kind: .gdrive,  state: .needsReauth))
        ctx.insert(Source(id: "src-disconnected",kind: .gdrive,  state: .disconnected))

        let tOffline = Track(title: "offline", artist: "", album: ""); ctx.insert(tOffline)
        let tReauth  = Track(title: "reauth",  artist: "", album: ""); ctx.insert(tReauth)
        let tGone    = Track(title: "gone",    artist: "", album: ""); ctx.insert(tGone)

        ctx.insert(FolderNode(id: "n-offline",      sourceId: "src-offline",      name: "N", parentId: nil, trackIds: [tOffline.id]))
        ctx.insert(FolderNode(id: "n-reauth",       sourceId: "src-reauth",       name: "N", parentId: nil, trackIds: [tReauth.id]))
        ctx.insert(FolderNode(id: "n-disconnected", sourceId: "src-disconnected", name: "N", parentId: nil, trackIds: [tGone.id]))

        ctx.insert(RootFolder(sourceId: "src-offline",      name: "R", nodeId: "n-offline"))
        ctx.insert(RootFolder(sourceId: "src-reauth",       name: "R", nodeId: "n-reauth"))
        ctx.insert(RootFolder(sourceId: "src-disconnected", name: "R", nodeId: "n-disconnected"))

        let idx = LibraryIndex(); idx.rebuild(from: ctx)

        XCTAssertTrue(idx.reachableTrackIds.contains(tOffline.id), "offline track must be reachable")
        XCTAssertTrue(idx.reachableTrackIds.contains(tReauth.id),  "needsReauth track must be reachable")
        XCTAssertFalse(idx.reachableTrackIds.contains(tGone.id),   "disconnected track must NOT be reachable")
    }

    func test_sameTrackUnderTwoFolders_countedOnce_deterministicPath() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "Mine", providerFolderId: "mine"))

        let dup = Track(title: "dup", artist: "", album: ""); ctx.insert(dup)
        let dupId = dup.id

        // "house" is listed before "dnb" in childFolderIds → house should win first-walk
        ctx.insert(FolderNode(id: "mine",  sourceId: "gdrive", name: "Mine",  parentId: nil,    childFolderIds: ["house", "dnb"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [dupId]))
        ctx.insert(FolderNode(id: "dnb",   sourceId: "gdrive", name: "DnB",   parentId: "mine", trackIds: [dupId]))

        let idx = LibraryIndex(); idx.rebuild(from: ctx)

        XCTAssertEqual(idx.reachableTrackIds.count, 1, "same track in two folders counted once in reachable")
        XCTAssertEqual(idx.sourceCounts["gdrive"]?.tracks, 1, "source tracks distinct count")
        // First-walk wins: mine → house (house precedes dnb in childFolderIds)
        XCTAssertEqual(idx.trackPath[dupId]?.folderIds, ["mine", "house"])
    }

    func test_cyclicFolderGraph_terminates() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "src", kind: .local, state: .connected))

        // a → b → a (cycle)
        ctx.insert(FolderNode(id: "a", sourceId: "src", name: "A", parentId: nil,  childFolderIds: ["b"]))
        ctx.insert(FolderNode(id: "b", sourceId: "src", name: "B", parentId: "a",  childFolderIds: ["a"]))
        ctx.insert(RootFolder(sourceId: "src", name: "R", nodeId: "a"))

        let idx = LibraryIndex()
        // Must return — no infinite loop / stack overflow.
        idx.rebuild(from: ctx)

        // Each folder visited at most once: "a" and "b" both in fCounts but counted once each.
        XCTAssertNotNil(idx.folderCounts["a"])
        XCTAssertEqual(idx.folderCounts["b"]?.folders, 0) // b's re-visit of a returns (0,[]) so b has 0 descendants
    }

    func test_danglingChildFolderId_ignored() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "src", kind: .local, state: .connected))

        let t = Track(title: "T", artist: "", album: ""); ctx.insert(t)
        // "ghost" child id has no FolderNode in the store
        ctx.insert(FolderNode(id: "root", sourceId: "src", name: "Root", parentId: nil,
                              childFolderIds: ["house", "ghost"], trackIds: [t.id]))
        ctx.insert(FolderNode(id: "house", sourceId: "src", name: "House", parentId: "root"))
        ctx.insert(RootFolder(sourceId: "src", name: "R", nodeId: "root"))

        let idx = LibraryIndex()
        idx.rebuild(from: ctx)   // must not crash

        XCTAssertTrue(idx.reachableTrackIds.contains(t.id), "present track still reachable")
        // Only "root" and "house" are counted; "ghost" silently skipped
        XCTAssertNotNil(idx.folderCounts["root"])
        XCTAssertNotNil(idx.folderCounts["house"])
    }

    func test_reachabilityFlipsOnStateChange() throws {
        let ctx = try TestDB.context()
        let source = Source(id: "flip", kind: .local, state: .connected)
        ctx.insert(source)

        let t = Track(title: "T", artist: "", album: ""); ctx.insert(t)
        ctx.insert(FolderNode(id: "n", sourceId: "flip", name: "N", parentId: nil, trackIds: [t.id]))
        ctx.insert(RootFolder(sourceId: "flip", name: "R", nodeId: "n"))

        let idx = LibraryIndex()

        // Connected → reachable
        idx.rebuild(from: ctx)
        XCTAssertTrue(idx.reachableTrackIds.contains(t.id))

        // Disconnect → not reachable
        source.state = SourceState.disconnected.rawValue
        idx.rebuild(from: ctx)
        XCTAssertFalse(idx.reachableTrackIds.contains(t.id))
        // Disconnected source is skipped entirely — no entry in sourceCounts
        XCTAssertNil(idx.sourceCounts["flip"])

        // Reconnect → reachable again
        source.state = SourceState.connected.rawValue
        idx.rebuild(from: ctx)
        XCTAssertTrue(idx.reachableTrackIds.contains(t.id))
    }

    func test_connectedSource_zeroRoots_zeroCounts() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "x", kind: .local, state: .connected))
        // No RootFolder rows for "x"

        let idx = LibraryIndex(); idx.rebuild(from: ctx)

        // No crash; source counted with zero folders and zero tracks
        XCTAssertEqual(idx.sourceCounts["x"], LibraryIndex.Counts(folders: 0, tracks: 0))
    }
}
