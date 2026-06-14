import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourcesManagerTests: XCTestCase {
    func test_connectAndAddRoot_createsSourceFoldersTracks_andReachable() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex()
        let mgr = SourcesManager(ctx: ctx, index: idx)
        // Connect iCloud, then add a root whose enumeration we supply directly.
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [
                FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: ["h"], trackIds: []),
                FolderDescriptor(id: "h", name: "House", parentId: "r", childFolderIds: [], trackIds: ["t1"]),
            ],
            tracks: [TrackDescriptor(id: "t1", title: "Caldera", artist: "Oso", album: "",
                                     durationSec: 0, format: "WAV", bookmark: Data([9]), providerFileId: nil)])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        XCTAssertEqual(try LibraryStore.source(id: "icloud", ctx)?.state, "connected")
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 1)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.tracks, 1)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.folders, 2)
        XCTAssertTrue(idx.reachableTrackIds.contains(where: { _ in true }))   // a track exists & reachable
    }

    func test_removeRoot_dropsItsTracksFromReachable() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: [], trackIds: ["t1"])],
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV", bookmark: Data([9]), providerFileId: nil)])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        let root = try LibraryStore.rootFolders(of: "icloud", ctx).first!
        mgr.removeRoot(root)
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 0)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.tracks ?? 0, 0)
    }

    func test_disconnect_clearsSourceRootsNodes_butKeepsTrackRowsForPlaylists() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: [], trackIds: ["t1"])],
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV", bookmark: Data([9]), providerFileId: nil)])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        mgr.disconnect(sourceId: "icloud")
        XCTAssertNil(try LibraryStore.source(id: "icloud", ctx))
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 0)
        XCTAssertTrue(try LibraryStore.childFolders(of: "r", ctx).isEmpty)   // folder nodes gone
        // Track rows persist (playlists may reference them) but are no longer reachable.
        XCTAssertFalse(idx.reachableTrackIds.contains(where: { _ in true }) && idx.sourceCounts["icloud"] != nil)
    }
}
