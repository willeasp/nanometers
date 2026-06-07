import Foundation

/// Pure transport state machine — the ordered queue, the current index, the shuffle/repeat
/// flags, and every next/prev/jump/shuffle transition. No AVFoundation: this is the piece the
/// spec calls out for unit tests (handoff §03 transport rules, §04 AudioEngine). The AudioEngine
/// owns one and turns its outputs into actual scheduling. Mirrors `app.jsx` goNext/goPrev/jumpTo.
struct PlaybackQueue {
    /// Fraction-into-track at/below which `prev` steps back instead of restarting
    /// (handoff §03: "prev: if >5% into the track, restart it; else go to previous track").
    static let prevRestartThreshold = 0.05

    /// What `prev` resolved to: restart the current track, or load a different one.
    enum PrevAction { case restartCurrent, play(Track) }

    private(set) var tracks: [Track] = []
    private(set) var index: Int = 0
    var isShuffle: Bool = false
    var isRepeat: Bool = false

    init(isShuffle: Bool = false, isRepeat: Bool = false) {
        self.isShuffle = isShuffle
        self.isRepeat = isRepeat
    }

    var current: Track? { tracks.indices.contains(index) ? tracks[index] : nil }

    /// Replace the queue with `list`, starting at `start` (clamped). Returns the track to play.
    mutating func load(_ list: [Track], startingAt start: Int) -> Track? {
        tracks = list
        index = list.indices.contains(start) ? start : 0
        return current
    }

    /// Replace the queue with a shuffled `list`; the element at `firstIndex` becomes current
    /// (callers pass a random index; tests pass a fixed one). Sets `isShuffle`.
    mutating func loadShuffled(_ list: [Track], firstIndex: Int) -> Track? {
        var rest = list
        var ordered: [Track] = []
        if rest.indices.contains(firstIndex) { ordered.append(rest.remove(at: firstIndex)) }
        rest.shuffle()
        ordered.append(contentsOf: rest)
        tracks = ordered
        index = 0
        isShuffle = true
        return current
    }

    /// Next track. Returns nil if playback should STOP (end of queue, repeat off); with repeat
    /// on, wraps to 0. On stop, `index` is left unchanged.
    mutating func advance() -> Track? {
        guard !tracks.isEmpty else { return nil }
        let next = index + 1
        if next >= tracks.count {
            guard isRepeat else { return nil }
            index = 0
            return current
        }
        index = next
        return current
    }

    /// Prev semantics (handoff §03). Mutates `index` only when stepping to a previous track.
    mutating func goPrev(progress: Double) -> PrevAction {
        if progress > Self.prevRestartThreshold { return .restartCurrent }
        index = max(0, index - 1)
        return .play(current ?? tracks.first ?? tracks[index])
    }

    /// Jump to an explicit index; nil (and no change) if out of range.
    mutating func jump(to i: Int) -> Track? {
        guard tracks.indices.contains(i) else { return nil }
        index = i
        return current
    }
}
