import SwiftUI

/// Live goniometer / vectorscope (handoff §06D.2): plots the engine's recent L/R sample pairs as a
/// Lissajous cloud — `M=(L+R)/√2` vertical, `S=(L−R)/√2` horizontal — in accent "phosphor" with
/// additive (`.plusLighter`) blending; brightness scales with `|M|+|S|`. Mono → a vertical line; wide
/// → spreads. Faint diamond + cross guide (white@6%) behind the cloud, no labels. Fades to a center dot when
/// there's no live audio (paused / silent), per the idle decision.
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
        var ctx = ctx
        ctx.clip(to: Path(CGRect(origin: .zero, size: size)))   // contain the cloud — never draw past the module's view
        let cx = w / 2, cy = h / 2
        let radius = min(w, h) / 2 - 8           // usable radius: the VIEW edge, inset 8 px so dots don't clip
        // `audioGain` is a gain on the AUDIO SOURCE (multiplied into the L/R samples in the plotting loop below).
        // It scales the CLOUD only. The diamond/cross reference frame is drawn at the fixed `radius` (view edge)
        // and is NOT touched by it — lowering the gain shrinks the cloud inside a frame that stays put. Calibrate
        // freely: lower = smaller cloud / more headroom before it reaches the frame. (The clip above is only an
        // overflow safety so a transient can never draw outside the module.) At 1/√2 a full-scale signal reaches
        // exactly the diamond, so the diamond encapsulates the cloud and a loud track fills it.
        let audioGain: Float = 0.70710677

        // Fixed reference frame at the view edge (white@6%), drawn at the constant `radius`: the outer diamond
        // border + cross axes, behind the cloud. (It earlier looked like an overlay only because the cloud's
        // own |m|+|s| brightness banding painted diamonds; that's gone now, so this faint frame reads cleanly.)
        var guide = Path()
        guide.move(to: CGPoint(x: cx, y: cy - radius)); guide.addLine(to: CGPoint(x: cx + radius, y: cy))
        guide.addLine(to: CGPoint(x: cx, y: cy + radius)); guide.addLine(to: CGPoint(x: cx - radius, y: cy)); guide.closeSubpath()
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

        // Uniform-brightness cloud: gather every point into ONE path and fill once. Brightness is deliberately
        // NOT keyed to |m|+|s| — that L1 distance's level-sets are DIAMONDS, so bucketing it painted concentric
        // diamond-shaped brightness bands ("layers", darker in the middle) over the cloud. A single uniform
        // additive fill keeps the cloud clean (and is cheaper: one fill, not six). `fade` dims it on idle.
        var cloud = Path()
        for i in 0..<n {
            let m = (l[i] + r[i]) * 0.7071 * audioGain         // input gain on the audio source
            let s = (l[i] - r[i]) * 0.7071 * audioGain
            let x = cx + CGFloat(s) * radius * fade            // full-radius geometry; audioGain sizes the cloud
            let y = cy - CGFloat(m) * radius * fade
            cloud.addRect(CGRect(x: x - dot / 2, y: y - dot / 2, width: dot, height: dot))
        }
        phosphor.fill(cloud, with: .color(Theme.accent.opacity(0.6 * Double(fade))))
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
