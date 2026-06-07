import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class DemoSeedTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        return ModelContext(container)
    }

    func test_seedsTwoBundledTracksOnceWhenEmpty() throws {
        let ctx = try makeContext()
        DemoSeed.seedIfEmpty(ctx)
        let seeded = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(seeded.count, 2)
        XCTAssertTrue(seeded.allSatisfy { $0.bundledName != nil })
        DemoSeed.seedIfEmpty(ctx)                              // idempotent — already populated
        XCTAssertEqual(try LibraryStore.allTracks(ctx).count, 2)
    }
}
