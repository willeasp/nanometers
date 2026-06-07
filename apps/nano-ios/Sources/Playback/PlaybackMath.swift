import AVFoundation

/// Pure playback math, kept out of `AudioEngine` so it's unit-testable. `progress` is derived
/// from the player node's sample time (handoff §04: "derive from sample time, not a timer").
enum PlaybackMath {
    /// 0…1 position from current sample frame and total frames; guards div-by-zero and overrun.
    static func fraction(frame: AVAudioFramePosition, total: AVAudioFramePosition) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(frame) / Double(total)))
    }

    /// "M:SS" from seconds, for the mono elapsed/remaining clock.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
