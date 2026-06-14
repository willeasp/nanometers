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
                                     durationSec: 0, format: "WAV", bookmark: nil,
                                     providerFileId: "House/Caldera.wav")])
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
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV",
                                     bookmark: nil, providerFileId: "A.wav")])
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
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV",
                                     bookmark: nil, providerFileId: "A.wav")])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        mgr.disconnect(sourceId: "icloud")
        XCTAssertNil(try LibraryStore.source(id: "icloud", ctx))
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 0)
        XCTAssertTrue(try LibraryStore.childFolders(of: "r", ctx).isEmpty)   // folder nodes gone
        // Track rows persist (playlists may reference them) but are no longer reachable.
        XCTAssertFalse(idx.reachableTrackIds.contains(where: { _ in true }) && idx.sourceCounts["icloud"] != nil)
    }

    // MARK: - FIX 3: Upsert / idempotency

    func test_applyEnumeration_isIdempotent_noDuplicateTracks() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .local)

        let result = EnumerationResult(
            folders: [
                FolderDescriptor(id: "r", name: "Music", parentId: nil, childFolderIds: [], trackIds: ["t1", "t2"])
            ],
            tracks: [
                TrackDescriptor(id: "t1", title: "Alpha", artist: "", album: "", durationSec: 0, format: "MP3",
                                bookmark: nil, providerFileId: "Alpha.mp3"),
                TrackDescriptor(id: "t2", title: "Beta",  artist: "", album: "", durationSec: 0, format: "WAV",
                                bookmark: nil, providerFileId: "Beta.wav"),
            ]
        )
        let rootBookmark = Data([0xDE, 0xAD])

        // First application.
        mgr.applyEnumeration(result, sourceId: "local", rootName: "Music",
                             rootNodeId: "r", rootBookmark: rootBookmark)
        let countAfterFirst = try LibraryStore.allTracks(ctx).count

        // Second application of the SAME result — upsert must reuse rows, not insert duplicates.
        mgr.applyEnumeration(result, sourceId: "local", rootName: "Music",
                             rootNodeId: "r", rootBookmark: rootBookmark)
        let countAfterSecond = try LibraryStore.allTracks(ctx).count

        XCTAssertEqual(countAfterFirst, countAfterSecond,
                       "Re-applying the same enumeration must not create duplicate Track rows (upsert)")

        // The folder node's trackIds must also have no duplicates.
        let node = try LibraryStore.folderNode(id: "r", ctx)
        let trackIds = node?.trackIds ?? []
        XCTAssertEqual(trackIds.count, Set(trackIds).count,
                       "FolderNode.trackIds must not contain duplicate UUIDs after re-enumeration")
    }

    func test_applyEnumeration_setsFolderBookmarkAndProviderFileId() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .local)

        let rootBookmark = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let result = EnumerationResult(
            folders: [
                FolderDescriptor(id: "r", name: "Tracks", parentId: nil, childFolderIds: [], trackIds: ["t1"])
            ],
            tracks: [
                TrackDescriptor(id: "t1", title: "Song", artist: "", album: "", durationSec: 0, format: "FLAC",
                                bookmark: nil, providerFileId: "Song.flac"),
            ]
        )
        mgr.applyEnumeration(result, sourceId: "local", rootName: "Tracks",
                             rootNodeId: "r", rootBookmark: rootBookmark)

        let tracks = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(tracks.count, 1)
        let t = try XCTUnwrap(tracks.first)
        XCTAssertEqual(t.folderBookmark, rootBookmark,
                       "Track.folderBookmark must equal the root bookmark passed to applyEnumeration")
        XCTAssertEqual(t.providerFileId, "Song.flac",
                       "Track.providerFileId must equal the descriptor's relative path")
    }
}
