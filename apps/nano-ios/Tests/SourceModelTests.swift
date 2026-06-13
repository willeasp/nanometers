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
}
