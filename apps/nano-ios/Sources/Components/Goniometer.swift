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
    var scopeBuffered: () -> Int     // frames currently in the ring — bounds the safe read window
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
                let head = scopeWritten()
                let end = cursor.endFrame(now: now, head: head, sampleRate: scopeRate())
                // Never read frames evicted from the ring. Rate-independent safety net: at very high
                // sample rates the cursor's max trailing window can exceed the fixed ring depth, which
                // would otherwise read zeros and collapse the cloud to center for a frame.
                let oldest = head - scopeBuffered()
                let safeEnd = max(end, min(head, oldest + windowFrames))
                let s = scopeWindow(safeEnd, windowFrames)
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
        let radius = min(w, h) / 2 - 8           // usable radius: the VIEW edge, inset 8 px so dots don't clip
        // Cloud scale: m=(L+R)/√2, s=(L−R)/√2 is an energy-preserving 45° rotation, so the |L|,|R|≤1 input
        // square maps to a diamond whose far corners (full-scale mono / anti-phase) sit at √2. Divide by √2 so
        // those corners land on `radius` = the VIEW edge: a loud track fills the scope to the rim but never
        // spills OUTSIDE the view. (The cloud may extend past the inner diamond guide below — that's wanted.)
        let plotR = radius / 1.4142135
        // Inner diamond reference, deliberately smaller than the view so the cloud breathes PAST it on loud
        // parts instead of looking encased (≈ −3 dB mono touches a vertex; full-scale reaches the view edge).
        let guideR = plotR

        // faint inner diamond (at guideR) + full-width cross orientation axes (white@6%)
        var guide = Path()
        guide.move(to: CGPoint(x: cx, y: cy - guideR)); guide.addLine(to: CGPoint(x: cx + guideR, y: cy))
        guide.addLine(to: CGPoint(x: cx, y: cy + guideR)); guide.addLine(to: CGPoint(x: cx - guideR, y: cy)); guide.closeSubpath()
        guide.move(to: CGPoint(x: cx, y: cy - radius)); guide.addLine(to: CGPoint(x: cx, y: cy + radius))
        guide.move(to: CGPoint(x: cx - radius, y: cy)); guide.addLine(to: CGPoint(x: cx + radius, y: cy))
        ctx.stroke(guide, with: .color(.white.opacity(0.06)), lineWidth: 1)

        var phosphor = ctx
        phosphor.blendMode = .plusLighter
        let dot: CGFloat = 1.6

        // Center dot — the "alive but silent" idle indicator the cloud fades onto (§06D.2 idle decision).
        phosphor.fill(Path(CGRect(x: cx - dot / 2, y: cy - dot / 2, width: dot, height: dot)),
                      with: .color(Theme.accent.opacity(0.2)))

        let n = min(l.count, r.count)
        guard n > 0, fade > 0.01 else { return }            // idle → just the center dot

        // Bucket points by brightness, fill each bucket ONCE — keeps the per-amplitude phosphor look
        // while collapsing ~1024 individual blended fills to a handful (fast enough for 120 Hz). The
        // representative opacity maps the bucket center back through the real brightness range AND keeps
        // the `fade` factor, so the cloud genuinely dims (not just collapses) as it idles out.
        let buckets = 6
        let bMin = 0.16, bMax = 0.85                          // per-point brightness floor … ~peak
        var paths = [Path](repeating: Path(), count: buckets)
        for i in 0..<n {
            let m = (l[i] + r[i]) * 0.7071
            let s = (l[i] - r[i]) * 0.7071
            let x = cx + CGFloat(s) * plotR * fade
            let y = cy - CGFloat(m) * plotR * fade
            let b = 0.16 + 0.45 * Double(abs(m) + abs(s))     // pre-fade brightness
            let t = min(1, max(0, (b - bMin) / (bMax - bMin)))
            let bi = min(buckets - 1, Int(t * Double(buckets)))
            paths[bi].addRect(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
        }
        for bi in 0..<buckets where !paths[bi].isEmpty {
            let center = (Double(bi) + 0.5) / Double(buckets)
            let rep = (bMin + center * (bMax - bMin)) * Double(fade)   // bucket brightness, faded
            phosphor.fill(paths[bi], with: .color(Theme.accent.opacity(min(1, max(0, rep)))))
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
