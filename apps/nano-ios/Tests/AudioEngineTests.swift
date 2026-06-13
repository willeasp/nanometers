import XCTest
import AVFoundation
@testable import NanoMeters

/// Verifies that playback genuinely renders audio — not just that UI/transport state flips.
/// It synthesizes a non-silent tone, plays it through the REAL `AudioEngine`, and asserts the
/// main-mixer `outputLevel` (RMS of the rendered signal) is non-zero while playing and ~zero when
/// paused. This is the headless "audio is actually coming out" check (the host-loopback capture
/// is the heavier end-to-end alternative; this needs no extra tooling).
@MainActor
final class AudioEngineTests: XCTestCase {
    func test_playbackProducesNonSilentOutput_thenSilenceWhenPaused() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 3.0, frequency: 440)

        let bookmark = try url.bookmarkData()
        let track = Track(title: "Tone", artist: "", album: "", bookmark: bookmark)

        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)
        XCTAssertTrue(engine.isPlaying, "engine should report playing after play()")

        // Let the engine render and the mixer tap accumulate a level.
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertGreaterThan(engine.outputLevel, 0.001,
                             "expected non-silent output while playing, got \(engine.outputLevel)")

        engine.toggle()   // pause → mixer renders silence
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertFalse(engine.isPlaying)
        XCTAssertLessThan(engine.outputLevel, 0.001,
                          "expected ~silence when paused, got \(engine.outputLevel)")
    }

    func test_liveShortTermLUFSBecomesAPlausibleReadingWhilePlaying() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 5.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)

        // Let > 3 s render so the 3 s short-term window is well-populated (it reads live within ~100 ms).
        try await Task.sleep(nanoseconds: 3_800_000_000)
        let s = engine.shortTermLUFS
        XCTAssertNotNil(s, "expected a live short-term reading after ~3.8 s, got nil")
        XCTAssertTrue((s ?? 0) > -40 && (s ?? 0) < 0, "live short-term implausible: \(String(describing: s))")

        engine.toggle()   // pause → blank-until-live: the badge value clears
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(engine.shortTermLUFS, "live short-term should blank when paused")
    }

    func test_centerTimeAdvancesWhilePlaying() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 3.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)

        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertGreaterThan(engine.centerTime, 0.3, "centerTime should advance with the sample clock")
    }

    /// Regression: pausing must NOT snap `centerTime` back to the last segment start. The close-up
    /// reads `centerTime` live each frame; before the fix, a paused read fell back to `seekOffsetFrames`
    /// (the scrub point ⇒ ~0 here) and the waveform jumped. It must hold at the play position.
    func test_centerTimeHoldsAcrossPause() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 5.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)

        try await Task.sleep(nanoseconds: 800_000_000)
        let playing = engine.centerTime
        XCTAssertGreaterThan(playing, 0.3, "centerTime should advance while playing, got \(playing)")

        engine.toggle()                                   // pause
        try await Task.sleep(nanoseconds: 300_000_000)
        let paused = engine.centerTime
        XCTAssertEqual(paused, playing, accuracy: 0.1,
                       "centerTime should hold across pause, not snap back (paused \(paused) vs playing \(playing))")
    }

    func test_setVolumeClampsToUnitRange() {
        let engine = AudioEngine()
        engine.setVolume(0.5);  XCTAssertEqual(engine.volume, 0.5, accuracy: 1e-6)
        engine.setVolume(1.7);  XCTAssertEqual(engine.volume, 1.0, accuracy: 1e-6)
        engine.setVolume(-0.3); XCTAssertEqual(engine.volume, 0.0, accuracy: 1e-6)
    }

    /// Writes `seconds` of a mono 44.1k float-WAV sine. The `AVAudioFile` writer is out of scope on
    /// return, so the file's header is finalized and it's immediately readable.
    private static func writeSine(to url: URL, seconds: Double, frequency: Double) throws {
        let sr = 44_100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let data = buf.floatChannelData![0]
        let w = 2.0 * Double.pi * frequency
        for i in 0..<Int(frames) { data[i] = Float(0.5 * sin(w * Double(i) / sr)) }
        try file.write(from: buf)
    }
}
