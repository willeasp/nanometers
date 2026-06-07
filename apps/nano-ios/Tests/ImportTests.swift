import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class ImportTests: XCTestCase {
    func test_importCreatesTrackFromAFile() async throws {
        // Write a tiny temp .wav-named file (metadata extraction is best-effort; the import must
        // still produce a Track with a resolvable bookmark and a sensible title fallback).
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("My_Bounce.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url) // "RIFF" — enough to exist
        defer { try? FileManager.default.removeItem(at: url) }

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)

        let imported = await TrackImporter.importFiles([url], into: ctx)
        XCTAssertEqual(imported, 1)
        let tracks = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(tracks.count, 1)
        let t = tracks[0]
        XCTAssertFalse(t.title.isEmpty)               // filename fallback at least
        XCTAssertEqual(t.sourceKind, SourceKind.local.rawValue)
        XCTAssertNotNil(t.bookmark)                    // bookmark stored
        // The stored bookmark resolves back to a URL.
        var stale = false
        let resolved = try URL(resolvingBookmarkData: t.bookmark!, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.lastPathComponent, "My_Bounce.wav")
    }
}
