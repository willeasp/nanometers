import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class DemoSeedTests: XCTestCase {
    func test_seedsOnceAndIncludesArtlessRows() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)

        DemoSeed.seedIfEmpty(ctx)
        let first = try LibraryStore.allTracks(ctx).count
        XCTAssertGreaterThan(first, 0)
        XCTAssertTrue(try LibraryStore.allTracks(ctx).contains { !$0.hasEmbeddedArt },
                      "at least one demo track is art-less to exercise the fallback")

        DemoSeed.seedIfEmpty(ctx)   // idempotent — must not duplicate
        XCTAssertEqual(try LibraryStore.allTracks(ctx).count, first)
    }
}
