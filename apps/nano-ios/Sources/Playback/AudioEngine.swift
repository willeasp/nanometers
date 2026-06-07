import Foundation
import AVFoundation
import Observation

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

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        configureSession()
        configureRemoteCommands()            // Task 10
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

    // MARK: Temporary stubs — replaced in Task 5 (transport) and Task 10 (now-playing/remote)
    func next() {}
    private func configureRemoteCommands() {}
    private func updateNowPlayingInfo() {}
}
