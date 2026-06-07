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
