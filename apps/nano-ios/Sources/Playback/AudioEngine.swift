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
    private var scopedURL: URL?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    private var seekOffsetFrames: AVAudioFramePosition = 0
    private var scheduleToken = 0            // invalidates stale completion callbacks
    private var ticker: Timer?
    // Written once in `configureRemoteCommands` (init), read once in `deinit` — no concurrent
    // access, so `nonisolated(unsafe)` lets the nonisolated deinit unregister our handlers.
    nonisolated(unsafe) private var remoteTargets: [(MPRemoteCommand, Any)] = []

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        installOutputMeter()
        configureSession()
        configureRemoteCommands()            // Task 10
    }

    /// Tap the main mixer and publish the rendered signal's RMS as `outputLevel` (real audio
    /// flowing ⇒ > 0). The tap lives and dies with this engine instance — no global state to clean.
    private func installOutputMeter() {
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buffer, _ in
            guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return }
            var rms: Float = 0
            vDSP_rmsqv(data[0], 1, &rms, vDSP_Length(buffer.frameLength))
            Task { @MainActor in self?.outputLevel = rms }
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
        } else {
            if !engine.isRunning { try? engine.start() }
            player.play(); isPlaying = true; startTicker()
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
        progress = 0; elapsed = 0; seekOffsetFrames = 0

        guard let url = resolveURL(track) else {
            // Unresolved file: reflect the selection, but don't fake audio.
            current = track; isPlaying = false; file = nil; totalFrames = 0
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
            NSLog("[AudioEngine] load failed for \(url.lastPathComponent): \(error)")
        }
    }

    /// Schedule `f` from `startFrame` to its end; advance to the next track when it finishes
    /// naturally (guarded by `scheduleToken` so manual stop/seek don't trigger an advance).
    private func schedule(_ f: AVAudioFile, from startFrame: AVAudioFramePosition) {
        scheduleToken &+= 1
        let token = scheduleToken
        seekOffsetFrames = startFrame
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

    /// Bundled samples resolve by name (no security scope); imported tracks via their bookmark.
    private func resolveURL(_ track: Track) -> URL? {
        if let name = track.bundledName,
           let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        guard let bm = track.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale) else { return nil }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        return url
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: Progress (sample time)

    private var currentFrame: AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return seekOffsetFrames }
        return seekOffsetFrames + playerTime.sampleTime
    }

    func updateProgress() {
        progress = PlaybackMath.fraction(frame: currentFrame, total: totalFrames)
        elapsed = sampleRate > 0 ? Double(currentFrame) / sampleRate : 0
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
            isPlaying = false; progress = 0; elapsed = 0
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

    func seek(toFraction f: Double) {
        guard let file, totalFrames > 0 else { return }
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
