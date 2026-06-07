import XCTest
import SwiftData
import AVFoundation
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

    func test_importReadsRealAudioDuration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write 1.0s of silence, then let the writer deallocate so the WAV header is finalized
        // (data-chunk size written) BEFORE we read it back — otherwise duration reads as 0.
        try Self.writeSilentWAV(to: url, seconds: 1.0)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)

        let n = await TrackImporter.importFiles([url], into: ctx)
        XCTAssertEqual(n, 1)
        let t = try LibraryStore.allTracks(ctx)[0]
        XCTAssertEqual(t.format, "WAV")
        XCTAssertEqual(t.durationSec, 1.0, accuracy: 0.1)   // real duration, not a fallback
    }

    /// Writes `seconds` of silence to a WAV at `url`. The `AVAudioFile` is fully out of scope when
    /// this returns, so its closing header (data-chunk size) is flushed and the file is readable.
    private static func writeSilentWAV(to url: URL, seconds: Double) throws {
        let sr = 44_100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)
    }
}
