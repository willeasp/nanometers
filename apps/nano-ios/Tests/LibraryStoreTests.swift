import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        return ModelContext(container)
    }

    func test_insertAndFetchTracks() throws {
        let ctx = try makeContext()
        ctx.insert(Track(title: "A", artist: "X", album: "Z"))
        ctx.insert(Track(title: "B", artist: "Y", album: "Z"))
        let all = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(all.count, 2)
    }

    func test_playlistKeepsExplicitOrder() throws {
        let ctx = try makeContext()
        let t1 = Track(title: "One", artist: "", album: "")
        let t2 = Track(title: "Two", artist: "", album: "")
        let t3 = Track(title: "Three", artist: "", album: "")
        [t1, t2, t3].forEach(ctx.insert)
        let pl = Playlist(name: "Mix")
        ctx.insert(pl)
        LibraryStore.append(t3, to: pl)   // deliberately out of insertion order
        LibraryStore.append(t1, to: pl)
        LibraryStore.append(t2, to: pl)
        let ordered = try LibraryStore.tracks(in: pl, ctx)
        XCTAssertEqual(ordered.map(\.title), ["Three", "One", "Two"])
    }

    func test_moveAndRemovePreserveOrder() throws {
        let ctx = try makeContext()
        let ts = (0..<4).map { Track(title: "\($0)", artist: "", album: "") }
        ts.forEach(ctx.insert)
        let pl = Playlist(name: "Q"); ctx.insert(pl)
        ts.forEach { LibraryStore.append($0, to: pl) }
        LibraryStore.move(in: pl, fromOffsets: IndexSet(integer: 0), toOffset: 4) // 0 -> end
        LibraryStore.remove(in: pl, atOffsets: IndexSet(integer: 0))              // drop new first ("1")
        let ordered = try LibraryStore.tracks(in: pl, ctx)
        XCTAssertEqual(ordered.map(\.title), ["2", "3", "0"])
    }
}
