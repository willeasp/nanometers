import XCTest
import AVFoundation
import MediaPlayer
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

    func test_liveMomentaryLUFSBecomesAPlausibleReadingWhilePlaying() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 5.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)

        // Momentary fills in ~400 ms; let a bit more than that render so the reading is well-populated.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let m = engine.momentaryLUFS
        XCTAssertNotNil(m, "expected a live momentary reading after ~1.5 s, got nil")
        XCTAssertTrue((m ?? 0) > -40 && (m ?? 0) < 0, "live momentary implausible: \(String(describing: m))")

        engine.toggle()   // pause → blank-until-live: the badge value clears
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertNil(engine.momentaryLUFS, "live momentary should blank when paused")
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

    /// Regression (FIX 5): a slow remote download for track A must not start playback of A if
    /// the user has already switched to track B. The load-generation guard detects the superseded
    /// load and bails; `current` must be B (not A) and A's `isPreparing` must not have cleared B's.
    ///
    /// We use a real-file B (bundled-name path, synchronous) to ensure B is actually loaded when
    /// A's slow provider resolves. A has a slow provider that resolves AFTER we've loaded B.
    func test_loadGeneration_staleRemoteLoad_doesNotSupersedeCurrent() async throws {
        // Write a silent WAV for track B that AudioEngine can open synchronously.
        let urlB = FileManager.default.temporaryDirectory
            .appendingPathComponent("GenGuard_B_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: urlB) }
        try Self.writeSine(to: urlB, seconds: 2.0, frequency: 220)
        let bmB = try urlB.bookmarkData()

        let engine = AudioEngine()

        // Track A: a cloud track (needsRemotePrep → true); its provider is slow.
        let trackA = Track(title: "CloudA", artist: "", album: "")
        trackA.providerFileId = "a1"
        trackA.sourceId = "gdrive"

        // Track B: a local track with a real bookmark; loads synchronously.
        let trackB = Track(title: "LocalB", artist: "", album: "", bookmark: bmB)

        // Continuation to signal that A's provider has been entered (we can then load B).
        let aContinuation = AsyncStream<Void>.makeStream()
        var aContinuationIterator = aContinuation.stream.makeAsyncIterator()

        // Wire a slow provider: yields to let the test proceed, then resolves to nil
        // (we don't have a real file for A; nil means "selection only", which is fine — the
        // generation guard fires before reaching loadFromURL regardless).
        engine.remoteURLProvider = { track in
            aContinuation.continuation.yield(())   // signal: A's download has started
            // Pause long enough for the test to load B (B loads synchronously, no delay needed).
            try? await Task.sleep(nanoseconds: 100_000_000)   // 100 ms
            return nil   // provider resolves; generation guard must block this from applying
        }

        // Start loading A (async, hits the slow provider).
        engine.play(trackA, in: [trackA, trackB], context: .library)
        XCTAssertEqual(engine.current?.id, trackA.id, "A must be reflected as current immediately")

        // Wait until A's remote Task has actually called the provider (it's in flight now).
        await aContinuationIterator.next()

        // Switch to B while A is still downloading.
        engine.play(trackB, in: [trackA, trackB], context: .library)

        // B loads synchronously; current must already be B.
        XCTAssertEqual(engine.current?.id, trackB.id, "B must be current after play(B)")

        // Let A's slow provider finish and the generation guard do its job.
        try await Task.sleep(nanoseconds: 200_000_000)   // 200 ms > A's 100 ms delay

        // B must still be current — A's stale completion must not have overwritten it.
        XCTAssertEqual(engine.current?.id, trackB.id,
                       "A's stale remote load must not overwrite B as current")
        // isPreparing must be false: B is a local track, no prep in flight.
        XCTAssertFalse(engine.isPreparing,
                       "isPreparing must be false after B (local) is loaded")
    }

    /// Regression: the system (lock-screen / Control Center) play-pause glyph is driven by
    /// `MPNowPlayingInfoCenter.playbackState`, which the engine must keep in lockstep with `isPlaying`.
    /// Before the fix only `MPNowPlayingInfoPropertyPlaybackRate` was set, so a system pause tap
    /// reverted the glyph back to "pause" while audio stayed paused — and the next tap (a pauseCommand
    /// on already-paused audio) was a no-op, so playback couldn't be resumed from the lock screen.
    func test_nowPlayingPlaybackStateTracksTransport() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 3.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        let center = MPNowPlayingInfoCenter.default()

        // play() resolves + schedules synchronously for a bundled/bookmark track, so state is set now.
        engine.play(track, in: [track], context: .library)
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(center.playbackState, .playing, "playbackState must be .playing after play()")

        engine.toggle()   // system pause
        XCTAssertFalse(engine.isPlaying)
        XCTAssertEqual(center.playbackState, .paused, "playbackState must be .paused after pausing")

        engine.toggle()   // system resume
        XCTAssertTrue(engine.isPlaying)
        XCTAssertEqual(center.playbackState, .playing, "playbackState must return to .playing on resume")
    }

    /// Regression: a system audio interruption (phone call / Siri) stops the engine WITHOUT going through
    /// our transport. The engine must mirror it to a paused state (so the lock screen and `isPlaying` don't
    /// lie about dead audio) and auto-resume when the interruption ends with `.shouldResume`.
    func test_systemInterruptionPausesThenResumesWhenAsked() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 5.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        let center = MPNowPlayingInfoCenter.default()
        engine.play(track, in: [track], context: .library)
        try await Task.sleep(nanoseconds: 400_000_000)   // render a little so there's a position to resume from
        XCTAssertTrue(engine.isPlaying)

        Self.postInterruption(.began)
        try await Task.sleep(nanoseconds: 150_000_000)   // allow the @MainActor hop
        XCTAssertFalse(engine.isPlaying, "interruption .began must mirror to a paused transport")
        XCTAssertEqual(center.playbackState, .paused, "lock screen must read paused during the interruption")

        Self.postInterruption(.ended, options: .shouldResume)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(engine.isPlaying, "interruption .ended (.shouldResume) must auto-resume")
        XCTAssertEqual(center.playbackState, .playing, "lock screen must read playing again after resume")
    }

    /// Without the `.shouldResume` hint, Apple's guidance is to stay paused until the user initiates
    /// playback — we must NOT auto-resume.
    func test_systemInterruptionEndWithoutShouldResumeStaysPaused() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 5.0, frequency: 440)

        let track = Track(title: "Tone", artist: "", album: "", bookmark: try url.bookmarkData())
        let engine = AudioEngine()
        engine.play(track, in: [track], context: .library)
        try await Task.sleep(nanoseconds: 400_000_000)
        XCTAssertTrue(engine.isPlaying)

        Self.postInterruption(.began)
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(engine.isPlaying)

        Self.postInterruption(.ended)   // no .shouldResume option
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(engine.isPlaying, "no .shouldResume → must wait for the user, not auto-resume")
    }

    /// Posts a fake `AVAudioSession.interruptionNotification` (matching the engine's `object: s` observer)
    /// so the handler's state machine can be exercised headlessly.
    private static func postInterruption(_ type: AVAudioSession.InterruptionType,
                                         options: AVAudioSession.InterruptionOptions? = nil) {
        var info: [AnyHashable: Any] = [AVAudioSessionInterruptionTypeKey: type.rawValue]
        if let options { info[AVAudioSessionInterruptionOptionKey] = options.rawValue }
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(), userInfo: info)
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
