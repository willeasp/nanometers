import SwiftUI

/// Live goniometer / vectorscope (handoff §06D.2): plots the engine's recent L/R sample pairs as a
/// Lissajous cloud — `M=(L+R)/√2` vertical, `S=(L−R)/√2` horizontal — in accent "phosphor" with
/// additive (`.plusLighter`) blending; brightness scales with `|M|+|S|`. Mono → a vertical line; wide
/// → spreads. Faint diamond + cross guide, no labels. Fades to a center dot when there's no live audio
/// (paused / silent), per the idle decision.
struct Goniometer: View {
    /// Monotonic frame clock + windowed reader of the live scope ring (see `ScopeCursor`). The gonio
    /// plots raw samples, so reading "the newest N" would stutter at the tap's ~10 Hz delivery; instead
    /// it scans a window through the buffered history at display rate.
    var scopeWritten: () -> Int
    var scopeRate: () -> Double
    var scopeWindow: (_ endingAt: Int, _ count: Int) -> (l: [Float], r: [Float], sampleRate: Double)
    var isPlaying: Bool
    var active: Bool

    private let windowFrames = 1024       // ~21–23 ms cloud; overlaps frame-to-frame so motion is smooth
    @State private var fade = MeterFade()
    @State private var cursor = ScopeCursor()

    var body: some View {
        TimelineView(.animation(paused: !active)) { timeline in
            Canvas { ctx, size in
                let now = timeline.date.timeIntervalSinceReferenceDate
                let end = cursor.endFrame(now: now, head: scopeWritten(), sampleRate: scopeRate())
                let s = scopeWindow(end, windowFrames)
                fade.step(towardLive: isPlaying && !s.l.isEmpty)
                draw(ctx, size, l: s.l, r: s.r, fade: CGFloat(fade.value))
            }
        }
        .accessibilityElement()
        .accessibilityIdentifier("goniometer")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, l: [Float], r: [Float], fade: CGFloat) {
        let w = size.width, h = size.height
        guard w > 2, h > 2 else { return }
        let cx = w / 2, cy = h / 2
        let radius = min(w, h) / 2 - 8

        // faint diamond + cross guide (white@6%)
        var guide = Path()
        guide.move(to: CGPoint(x: cx, y: cy - radius)); guide.addLine(to: CGPoint(x: cx + radius, y: cy))
        guide.addLine(to: CGPoint(x: cx, y: cy + radius)); guide.addLine(to: CGPoint(x: cx - radius, y: cy)); guide.closeSubpath()
        guide.move(to: CGPoint(x: cx, y: cy - radius)); guide.addLine(to: CGPoint(x: cx, y: cy + radius))
        guide.move(to: CGPoint(x: cx - radius, y: cy)); guide.addLine(to: CGPoint(x: cx + radius, y: cy))
        ctx.stroke(guide, with: .color(.white.opacity(0.06)), lineWidth: 1)

        let n = min(l.count, r.count)
        guard n > 0, fade > 0.01 else { return }

        // Bucket points by brightness and fill each bucket ONCE — keeps the per-amplitude phosphor look
        // while collapsing ~1024 individual blended fills (slow) to a handful, so the cloud sustains the
        // display rate even at the larger point count / on 120 Hz.
        var phosphor = ctx
        phosphor.blendMode = .plusLighter
        let dot: CGFloat = 1.6
        let buckets = 6
        var paths = [Path](repeating: Path(), count: buckets)
        for i in 0..<n {
            let m = (l[i] + r[i]) * 0.7071
            let s = (l[i] - r[i]) * 0.7071
            let x = cx + CGFloat(s) * radius * fade
            let y = cy - CGFloat(m) * radius * fade
            let a = (0.16 + 0.45 * Double(abs(m) + abs(s))) * Double(fade)
            let bi = min(buckets - 1, max(0, Int(a * Double(buckets))))
            paths[bi].addRect(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
        }
        for bi in 0..<buckets where !paths[bi].isEmpty {
            let a = (Double(bi) + 0.5) / Double(buckets)        // bucket's representative brightness
            phosphor.fill(paths[bi], with: .color(Theme.accent.opacity(min(1, max(0, a)))))
        }
    }
}

/// Smooth idle fade shared by the live meters: snaps to 1 while audio flows, decays toward 0 when it
/// stops (so the goniometer collapses to a center dot). A reference type in `@State` so it persists
/// across frames without triggering SwiftUI invalidation.
final class MeterFade {
    private(set) var value: Double = 0
    func step(towardLive live: Bool) {
        value = live ? 1 : value * 0.90
        if value < 0.001 { value = 0 }
    }
}
