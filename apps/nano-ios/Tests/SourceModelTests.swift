import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourceModelTests: XCTestCase {
    func test_allSources_sortedByCanonicalOrder_regardlessOfInsertOrder() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))   // inserted first
        ctx.insert(Source(id: "local", kind: .local, state: .connected))
        let sources = try LibraryStore.allSources(ctx)
        XCTAssertEqual(sources.map(\.id), ["local", "gdrive"])
    }

    func test_source_defaultsFromKind() throws {
        let ctx = try TestDB.context()
        let s = Source(id: "gdrive", kind: .gdrive, state: .noRoots)
        ctx.insert(s)
        let fetched = try LibraryStore.source(id: "gdrive", ctx)
        XCTAssertEqual(fetched?.label, "Google Drive")
        XCTAssertEqual(fetched?.tintHex, "#6FCF72")
        XCTAssertEqual(fetched?.canonicalOrder, 2)
        XCTAssertEqual(fetched?.state, "noRoots")
    }

    func test_rootFolders_filteredBySource_inAddOrder() throws {
        let ctx = try TestDB.context()
        let early = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "gd-mine", dateAdded: early))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "DJ Crate", providerFolderId: "gd-crate", dateAdded: later))
        ctx.insert(RootFolder(sourceId: "local", name: "On My iPhone", bookmark: Data([1,2]), dateAdded: early))
        let driveRoots = try LibraryStore.rootFolders(of: "gdrive", ctx)
        XCTAssertEqual(driveRoots.map(\.name), ["My Productions", "DJ Crate"])
    }

    func test_track_sourceRefs_defaultNil_andPersist() throws {
        let ctx = try TestDB.context()
        let t = Track(title: "A", artist: "", album: "")
        XCTAssertNil(t.sourceId)
        XCTAssertNil(t.folderId)
        XCTAssertNil(t.providerFileId)
        t.sourceId = "gdrive"; t.folderId = "house"; t.providerFileId = "drive-file-1"
        ctx.insert(t)
        let fetched = try LibraryStore.track(id: t.id, ctx)
        XCTAssertEqual(fetched?.sourceId, "gdrive")
        XCTAssertEqual(fetched?.folderId, "house")
        XCTAssertEqual(fetched?.providerFileId, "drive-file-1")
    }
}
