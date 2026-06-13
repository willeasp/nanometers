import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourcesMigrationTests: XCTestCase {
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
}
