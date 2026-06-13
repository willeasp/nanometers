import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourcesMigrationTests: XCTestCase {
    func test_migration_doesNotClobberNonLocalSource() throws {
        let ctx = try TestDB.context()

        // Pre-insert a gdrive source and a track that belongs to it.
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        let gdriveTrack = Track(title: "CloudTrack", artist: "", album: "",
                                sourceKind: SourceKind.gdrive.rawValue)
        gdriveTrack.sourceId = "gdrive"
        gdriveTrack.folderId = "drive-x"
        ctx.insert(gdriveTrack)

        // Also a pre-existing local track that has no sourceId yet (pre-migration state).
        let localTrack = Track(title: "LocalTrack", artist: "", album: "",
                               sourceKind: SourceKind.local.rawValue)
        // sourceId is nil — pre-migration state
        ctx.insert(localTrack)

        SourcesMigration.runIfNeeded(ctx)

        // The gdrive track must be untouched.
        let fetched = try LibraryStore.track(id: gdriveTrack.id, ctx)
        XCTAssertEqual(fetched?.sourceId, "gdrive", "gdrive track sourceId must not change")
        XCTAssertEqual(fetched?.folderId, "drive-x", "gdrive track folderId must not change")

        // The gdrive track must NOT appear in the local-root node's trackIds.
        let node = try LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx)
        XCTAssertFalse(node?.trackIds.contains(gdriveTrack.id) ?? false,
                       "gdrive track must not be swept into local root")

        // The local track (sourceKind == local, nil sourceId) must be attached by the migration.
        // Note: the tightened filter is `sourceKind == local` only, so localTrack qualifies.
        XCTAssertEqual(try LibraryStore.track(id: localTrack.id, ctx)?.sourceId, "local",
                       "local track must be attached to local source")
        XCTAssertTrue(node?.trackIds.contains(localTrack.id) ?? false,
                      "local track must appear in the local root node")
    }

    func test_run_seedsLocalSource_andAttachesExistingTracks() throws {
        let ctx = try TestDB.context()
        let t1 = Track(title: "A", artist: "", album: "")
        let t2 = Track(title: "B", artist: "", album: "")
        [t1, t2].forEach(ctx.insert)

        SourcesMigration.runIfNeeded(ctx)

        let local = try LibraryStore.source(id: "local", ctx)
        XCTAssertEqual(local?.state, "connected")
        let roots = try LibraryStore.rootFolders(of: "local", ctx)
        XCTAssertEqual(roots.count, 1)
        // Every existing track is now attached to the local root node.
        let node = try LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx)
        XCTAssertEqual(Set(node?.trackIds ?? []), Set([t1.id, t2.id]))
        XCTAssertEqual(try LibraryStore.track(id: t1.id, ctx)?.sourceId, "local")
        XCTAssertEqual(try LibraryStore.track(id: t1.id, ctx)?.folderId, SourcesMigration.localRootNodeId)
    }

    func test_run_isIdempotent() throws {
        let ctx = try TestDB.context()
        ctx.insert(Track(title: "A", artist: "", album: ""))
        SourcesMigration.runIfNeeded(ctx)
        SourcesMigration.runIfNeeded(ctx)   // second run must not duplicate
        XCTAssertEqual(try LibraryStore.allSources(ctx).count, 1)
        XCTAssertEqual(try LibraryStore.rootFolders(of: "local", ctx).count, 1)
    }

    func test_launchSequence_seedThenMigrate_attachesDemoTracks() throws {
        let ctx = try TestDB.context()
        DemoSeed.seedIfEmpty(ctx)            // first-run demo content
        SourcesMigration.runIfNeeded(ctx)    // then attach to local source

        let node = try LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx)
        let demoTitles = try LibraryStore.tracksInFolder(id: SourcesMigration.localRootNodeId, ctx).map(\.title)
        XCTAssertEqual(node?.sourceId, "local")
        XCTAssertEqual(Set(demoTitles), ["Biljam", "Mercy"])
    }
}
