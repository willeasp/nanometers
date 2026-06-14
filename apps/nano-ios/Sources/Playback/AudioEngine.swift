import Foundation
import AVFoundation
import MediaPlayer
import Observation
import UIKit
import Accelerate

/// The playback engine (handoff §04). `@MainActor @Observable` so SwiftUI reads `current`,
/// `isPlaying`, `progress` directly. Owns a pure `PlaybackQueue` and an `AVAudioEngine`/
/// `AVAudioPlayerNode`; resolves a Track to a file URL (bundled sample by name, else imported
/// file via its security-scoped bookmark), opens an `AVAudioFile`, schedules it, and derives
/// `progress` from the node's sample time. Tracks with no resolvable file are a no-op — we never
/// fake audio.
@MainActor
@Observable
final class AudioEngine {
    // Observable transport state.
    private(set) var current: Track?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0    // 0…1
    private(set) var elapsed: Double = 0     // seconds
    /// RMS of the signal at the main mixer — the audio actually being rendered to the output.
    /// Non-zero only while real sound is flowing; foundation for the Phase 5 live meter (ADR 0002).
    private(set) var outputLevel: Float = 0
    /// Live momentary (400 ms) BS.1770 loudness, fed by the main-mixer tap — faster / more reactive than
    /// short-term. A reading appears within ~400 ms of playback; nil only before the first audio renders,
    /// right after a reset (until the next feed), or on true silence. Transient — NOT persisted on Track.
    private(set) var momentaryLUFS: Double?
    /// Player gain, 0…1. Drives `player.volume`; NOT system volume.
    private(set) var volume: Double = 1.0
    private(set) var context: PlayContext = .library
    var isRepeat: Bool {
        get { queue.isRepeat }
        set { queue.isRepeat = newValue; updateNowPlayingInfo() }
    }
    var isShuffle: Bool { queue.isShuffle }

    // Queue + audio graph.
    var queue = PlaybackQueue()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    /// Streaming momentary loudness, fed from `installOutputMeter`'s tap. Off-main + lock-guarded.
    private let liveMeter = LiveLUFSMeter()
    /// Eased value behind `momentaryLUFS` — display ballistics so the badge reads calmly (see updateProgress).
    @ObservationIgnored private var smoothedLUFS: Double?
    /// Counts 20 Hz ticks so the visible LUFS number refreshes once per second, not every tick (see updateProgress).
    @ObservationIgnored private var meterPublishTick = 0
    private let meterPublishEvery = 20   // 20 Hz ticker ÷ 20 = 1 Hz readout
    private var scopedURL: URL?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    private var seekOffsetFrames: AVAudioFramePosition = 0
    @ObservationIgnored private var lastKnownFrame: AVAudioFramePosition = 0  // cache mutated on read in currentFrame; never observed
    private var scheduleToken = 0            // invalidates stale completion callbacks
    private var ticker: Timer?
    // Written once in `configureRemoteCommands` (init), read once in the nonisolated `deinit` to
    // unregister our handlers. `nonisolated(unsafe)` is REQUIRED for that deinit access in this build
    // (dropping it is a hard "main actor-isolated property" error — the "has no effect" warning is
    // spurious); safe because access is single-write-in-init / single-read-in-deinit, never concurrent.
    nonisolated(unsafe) private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        installOutputMeter()
        configureSession()
        configureRemoteCommands()            // Task 10
    }

    /// Tap the main mixer and feed the live meter (RMS level + short-term LUFS). The tap runs on the
    /// audio render thread, so it must not allocate a `Task` or touch the main actor per callback — it
    /// only stashes the readings into `liveMeter` (lock-guarded). The 20 Hz `updateProgress` ticker
    /// publishes them to the observable `outputLevel` / `momentaryLUFS`, so the UI invalidates at 20 Hz,
    /// not the tap's ~47 Hz — which is what was starving the close-up's TimelineView. The tap lives and
    /// dies with this engine instance (no self capture, no global state to clean).
    private func installOutputMeter() {
        let meter = liveMeter        // capture the off-main, lock-guarded handle for the tap thread
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            let frames = Int(buffer.frameLength)
            var rms: Float = 0
            vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(frames))
            let stereo = buffer.format.channelCount > 1
            meter.feed(left: data[0], right: stereo ? data[1] : data[0],
                       frames: frames, sampleRate: buffer.format.sampleRate, level: rms)
        }
    }

    deinit {
        // Remove our handlers from the process-global command center so a re-instantiated engine
        // (SwiftUI previews, tests) doesn't stack duplicate remote-command handlers.
        remoteTargets.forEach { $0.0.removeTarget($0.1) }
    }

    // MARK: Public API (handoff §04)

    func play(_ track: Track, in list: [Track], context: PlayContext) {
        self.context = context
        let start = list.firstIndex { $0.id == track.id } ?? 0
        if let t = queue.load(list, startingAt: start) { loadAndStart(t) }
    }

    func toggle() {
        guard current != nil, file != nil else { return }   // nothing loaded / unresolved file
        if isPlaying {
            player.pause(); isPlaying = false; stopTicker()
            outputLevel = 0; momentaryLUFS = nil          // ticker stopped → clear the live meter explicitly
        } else {
            if !engine.isRunning { try? engine.start() }
            player.play(); isPlaying = true; startTicker()
            liveMeter.requestReset()                       // fresh 3 s window on resume
        }
        updateNowPlayingInfo()
    }

    func setVolume(_ v: Double) {
        let clamped = min(1, max(0, v))
        volume = clamped
        player.volume = Float(clamped)
    }

    // MARK: Loading / scheduling

    private func loadAndStart(_ track: Track) {
        stopTicker()
        player.stop()
        releaseScope()
        progress = 0; elapsed = 0; seekOffsetFrames = 0; lastKnownFrame = 0; outputLevel = 0
        liveMeter.requestReset(); momentaryLUFS = nil          // drop the stale meter window for the new track

        guard let url = resolveURL(track) else {
            // Unresolved file: reflect the selection, but don't fake audio.
            current = track; isPlaying = false; file = nil; totalFrames = 0
            liveMeter.stop(); momentaryLUFS = nil
            updateNowPlayingInfo()
            NSLog("[AudioEngine] no playable file for \(track.title) — selection only")
            return
        }
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            totalFrames = f.length
            sampleRate = f.processingFormat.sampleRate
            engine.connect(player, to: engine.mainMixerNode, format: f.processingFormat)
            if !engine.isRunning { try engine.start() }
            schedule(f, from: 0)
            current = track
            player.play(); isPlaying = true
            startTicker()
            updateNowPlayingInfo()
        } catch {
            current = track; isPlaying = false; file = nil; totalFrames = 0
            liveMeter.stop(); momentaryLUFS = nil
            NSLog("[AudioEngine] load failed for \(url.lastPathComponent): \(error)")
        }
    }

    /// Schedule `f` from `startFrame` to its end; advance to the next track when it finishes
    /// naturally (guarded by `scheduleToken` so manual stop/seek don't trigger an advance).
    private func schedule(_ f: AVAudioFile, from startFrame: AVAudioFramePosition) {
        scheduleToken &+= 1
        let token = scheduleToken
        seekOffsetFrames = startFrame
        lastKnownFrame = startFrame          // hold this position if read while paused (no node clock yet)
        let remaining = AVAudioFrameCount(max(0, totalFrames - startFrame))
        guard remaining > 0 else { handlePlaybackEnded(token: token); return }
        player.scheduleSegment(f, startingFrame: startFrame, frameCount: remaining, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded(token: token) }
        }
    }

    private func handlePlaybackEnded(token: Int) {
        guard token == scheduleToken else { return }   // superseded by seek / next / new load
        next()                                           // Task 5
    }

    /// Resolve a Track to a playable file URL, in priority order:
    /// 1. Bundled sample by name (no security scope needed).
    /// 2. Direct per-file security-scoped bookmark (TrackImporter imports).
    /// 3. Root folder bookmark + relative providerFileId (enumerated local tracks, FIX d).
    /// 4. nil → cloud track or unresolvable (handled upstream / by Phase 5 prep).
    private func resolveURL(_ track: Track) -> URL? {
        // (1) Bundle resource
        if let name = track.bundledName,
           let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }

        // (2) Direct per-file bookmark (TrackImporter path: bookmark is non-nil)
        if let bm = track.bookmark {
            var stale = false
            guard let url = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale) else { return nil }
            if url.startAccessingSecurityScopedResource() { scopedURL = url }
            return url
        }

        // (3) Root folder bookmark + relative path (enumerated local/iCloud tracks).
        // Cloud tracks have folderBookmark == nil, so they fall through to nil here.
        if let fbm = track.folderBookmark, let rel = track.providerFileId, !rel.isEmpty {
            var stale = false
            guard let folderURL = try? URL(resolvingBookmarkData: fbm, bookmarkDataIsStale: &stale)
            else { return nil }
            // Hold the security scope on the FOLDER (not per-file); releaseScope() stops it.
            if folderURL.startAccessingSecurityScopedResource() { scopedURL = folderURL }
            return folderURL.appendingPathComponent(rel)
        }

        // (4) Cloud / unresolvable → nil (Phase 5 will prep the remote file before calling loadAndStart)
        return nil
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: Progress (sample time)

    /// Best-known sample position, held across pause. The node clock is only readable while the player
    /// is actually rendering; the instant we pause, `playerTime(forNodeTime:)` returns nil. Falling back
    /// to `seekOffsetFrames` (the last segment start) snapped the position back to the last scrub point —
    /// which the close-up, reading `centerTime` live each frame, showed as a jump on pause. So cache every
    /// valid read and return it when the clock is gone. `lastKnownFrame` is also set wherever we set a
    /// known position (load / seek / end-of-queue) so a paused scrub still reads correctly.
    private var currentFrame: AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return lastKnownFrame }
        lastKnownFrame = seekOffsetFrames + playerTime.sampleTime
        return lastKnownFrame
    }

    /// Sample-accurate playback position in seconds — the close-up's `centerTime`. Reads the player
    /// node clock live (handoff §05: derive from sample time, never a wall clock).
    var centerTime: Double { sampleRate > 0 ? Double(currentFrame) / sampleRate : 0 }

    func updateProgress() {
        progress = PlaybackMath.fraction(frame: currentFrame, total: totalFrames)
        elapsed = sampleRate > 0 ? Double(currentFrame) / sampleRate : 0
        // Publish the live meter at the ticker's 20 Hz (not the tap's ~47 Hz) so the LUFS badge doesn't
        // invalidate Now Playing every audio callback and starve the close-up's TimelineView. Guard on
        // `isPlaying` so this is the single authority on "live only while playing": a tick's Task that the
        // run loop drains AFTER a synchronous pause/stop re-establishes the cleared state instead of
        // resurrecting a stale momentary reading (the tap keeps feeding the meter after pause).
        if isPlaying {
            let m = liveMeter.snapshot()
            outputLevel = m.level
            // The badge "refreshes too often" if we publish every 20 Hz tick. Two levers: ease the value
            // (EMA, τ ≈ 0.8 s) AND refresh the visible number once per second (every `meterPublishEvery` ticks),
            // so the digit sits still long enough to read. The EMA runs every tick (continuous smoothing);
            // the publish samples it. Seeds immediately on the first reading after a reset, then holds.
            if let mo = m.momentary {
                let eased = smoothedLUFS.map { $0 + (mo - $0) * 0.06 } ?? mo
                smoothedLUFS = eased
                meterPublishTick += 1
                if meterPublishTick >= meterPublishEvery || momentaryLUFS == nil {
                    meterPublishTick = 0
                    momentaryLUFS = (eased * 10).rounded() / 10   // 0.1 dB precision (the badge's %.1f)
                }
            } else {
                smoothedLUFS = nil
                momentaryLUFS = nil
            }
        } else {
            outputLevel = 0
            smoothedLUFS = nil
            momentaryLUFS = nil
            meterPublishTick = 0
        }
        // The lock-screen position is anchored at play/pause/seek/track-change (iOS extrapolates
        // from rate + elapsed), so there's no need to re-push now-playing info every tick.
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    // MARK: Session

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
    }

    // MARK: Transport (Task 5)

    func next() {
        if let t = queue.advance() {
            loadAndStart(t)
        } else {                       // end of queue, repeat off → stop
            player.stop(); stopTicker(); releaseScope()
            isPlaying = false; progress = 0; elapsed = 0; lastKnownFrame = 0; outputLevel = 0
            liveMeter.stop(); momentaryLUFS = nil
            updateNowPlayingInfo()
        }
    }

    func prev() {
        switch queue.goPrev(progress: progress) {
        case .restartCurrent: seek(toFraction: 0)
        case .play(let t):    loadAndStart(t)
        }
    }

    func jump(to i: Int) {
        if let t = queue.jump(to: i) { loadAndStart(t) }
    }

    func playShuffle(_ list: [Track], context: PlayContext) {
        guard !list.isEmpty else { return }
        self.context = context
        let first = Int.random(in: 0..<list.count)
        if let t = queue.loadShuffled(list, firstIndex: first) { loadAndStart(t) }
    }

    func setShuffle(_ on: Bool) { queue.isShuffle = on }   // flag only; reorder happens via playShuffle

    func toggleShuffle() {
        if queue.isShuffle { queue.isShuffle = false }
        else { queue.reshuffleRemaining() }
    }
    func setRepeat(_ on: Bool) { isRepeat = on }

    func playNext(_ track: Track) { queue.insertNext(track) }
    func enqueue(_ track: Track)  { queue.append(track) }

    func seek(toFraction f: Double) {
        guard let file, totalFrames > 0 else { return }
        liveMeter.requestReset(); momentaryLUFS = nil
        let target = AVAudioFramePosition(Double(totalFrames) * min(1, max(0, f)))
        let wasPlaying = isPlaying
        player.stop()
        schedule(file, from: target)
        if wasPlaying { if !engine.isRunning { try? engine.start() }; player.play() }
        updateProgress()
        updateNowPlayingInfo()
    }

    // MARK: Now-playing + remote commands (Task 10)

    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        remoteTargets = [
            (c.playCommand,            c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }),
            (c.pauseCommand,           c.pauseCommand.addTarget { [weak self] _ in self?.pausePlayback(); return .success }),
            (c.togglePlayPauseCommand, c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }),
            (c.nextTrackCommand,       c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }),
            (c.previousTrackCommand,   c.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }),
            (c.changePlaybackPositionCommand, c.changePlaybackPositionCommand.addTarget { [weak self] event in
                guard let self,
                      let e = event as? MPChangePlaybackPositionCommandEvent,
                      self.totalFrames > 0, self.sampleRate > 0 else { return .commandFailed }
                self.seek(toFraction: e.positionTime * self.sampleRate / Double(self.totalFrames))
                return .success
            }),
        ]
    }

    private func resume() { if !isPlaying { toggle() } }
    private func pausePlayback() { if isPlaying { toggle() } }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = current else { center.nowPlayingInfo = nil; return }
        let duration = totalFrames > 0 && sampleRate > 0 ? Double(totalFrames) / sampleRate : t.durationSec
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let data = t.artworkData, let img = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
    }
}
