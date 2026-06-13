import SwiftUI

/// Close-up scope (handoff §06D.1) — the flip card's signature meter. A window of the cached **stereo**
/// bins scrolling right→left past a FIXED center playhead, drawn in the nano-plugin Waveform look: a
/// FILLED min/max contour per channel, **L in the top half, R in the bottom half**, spectrally colored.
/// Uniform brightness (no played/upcoming dimming), a soft edge-fade, and scrub-anywhere-to-seek. The
/// playhead is advanced by `ScrollClock` — the plugin's "subway-sign" model: a frame-counted,
/// reservoir-controlled step once per `TimelineView` vsync tick whose RATE slews toward the
/// sample-accurate `centerTime`, rather than reading the clock straight into the position each frame
/// (which staircases to the audio render cadence). Transparent, chrome-free — it draws straight onto
/// the card-back (§06C: no label, no box).
struct CloseUpWaveform: View {
    var bins: [StereoWaveBin]
    var currentTime: () -> Double      // the audio sample clock (seconds) the ScrollClock slews its rate toward
    var duration: Double
    var coloringOn: Bool = true
    var isPlaying: Bool
    /// Observed seek/elapsed value (pass `engine.elapsed`). While PAUSED the `TimelineView` schedule is
    /// frozen and `ScrollClock` holds at `currentTime()`, so this value changing on a scrub is what forces
    /// a re-render to re-center the held playhead (§06: a scrub re-centers the close-up even when paused).
    var redrawTrigger: Double
    var windowSec: Double = 4          // §06D.1 close-up window (3/4/5 s)
    var onScrub: (Double) -> Void = { _ in }

    @State private var clock = ScrollClock()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: !isPlaying)) { timeline in
                Canvas { ctx, size in
                    let now = timeline.date.timeIntervalSinceReferenceDate
                    let center = clock.present(now: now, audio: currentTime(), playing: isPlaying)
                    _ = redrawTrigger   // referenced so a paused scrub re-renders (see doc)
                    draw(ctx, size, center: center)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    guard duration > 0, geo.size.width > 0 else { return }
                    let off = Double((v.location.x - geo.size.width / 2) / geo.size.width) * windowSec
                    onScrub(min(1, max(0, (currentTime() + off) / duration)))
                }
            )
        }
        .accessibilityElement()
        .accessibilityIdentifier("closeUpWaveform")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, center: Double) {
        guard !bins.isEmpty, duration > 0 else { return }
        let w = size.width, h = size.height
        guard w > 1, h > 1 else { return }
        let barsPerSec = Double(bins.count) / duration
        let win = max(0.5, windowSec)
        let pxPerSec = w / CGFloat(win)
        let centerX = w / 2
        let chTop = h * 0.25, chBot = h * 0.75       // per-channel zero-lines (L top half, R bottom half)
        let halfAmp = (h / 2) * 0.45                 // plugin HALF_SCALE within each half
        let halfPx = Double(0.5 / pxPerSec)          // half a column, in seconds (for per-pixel aggregation)

        // whisper-faint center axis (white@5%) at the L/R divider
        ctx.fill(Path(CGRect(x: 0, y: (h / 2).rounded(), width: w, height: 1)), with: .color(.white.opacity(0.05)))

        // One vertical column per device point (§06D.1 pixel-per-column). Each column aggregates the
        // min/max over the cache bins it spans (no aliasing when the cache is denser than the screen),
        // then fills L (top half) and R (bottom half) — the plugin's filled min/max contour look.
        var x: CGFloat = 0
        while x < w {
            let tc = center + Double((x + 0.5 - centerX) / pxPerSec)
            let t0 = tc - halfPx, t1 = tc + halfPx
            if t1 >= 0 && t0 <= duration {
                var i0 = Int(max(0, t0) * barsPerSec)
                var i1 = Int(min(duration, t1) * barsPerSec)
                i0 = max(0, min(bins.count - 1, i0)); i1 = max(0, min(bins.count - 1, i1))
                if i1 < i0 { i1 = i0 }
                var lMin: Float = 0, lMax: Float = 0, rMin: Float = 0, rMax: Float = 0
                for k in i0...i1 {
                    let b = bins[k]
                    lMin = min(lMin, b.lMin); lMax = max(lMax, b.lMax)
                    rMin = min(rMin, b.rMin); rMax = max(rMax, b.rMax)
                }
                let mid = bins[(i0 + i1) / 2]
                let edge = min(1, Double(min(x, w - x)) / Double(w * 0.10))   // §06 edge fade; uniform otherwise
                if edge > 0 {
                    let col = (coloringOn ? Self.scopeColor(mid) : Theme.accent).opacity(edge)
                    let lTop = chTop - CGFloat(lMax) * halfAmp, lBot = chTop - CGFloat(lMin) * halfAmp
                    ctx.fill(Path(CGRect(x: x, y: lTop, width: 1.5, height: max(1, lBot - lTop))), with: .color(col))
                    let rTop = chBot - CGFloat(rMax) * halfAmp, rBot = chBot - CGFloat(rMin) * halfAmp
                    ctx.fill(Path(CGRect(x: x, y: rTop, width: 1.5, height: max(1, rBot - rTop))), with: .color(col))
                }
            }
            x += 1
        }

        // soft center playhead — vertical white gradient (transparent → 0.7 → transparent), §06D.1.
        ctx.fill(Path(CGRect(x: centerX - 1, y: 0, width: 2, height: h)),
                 with: .linearGradient(
                    Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                     .init(color: .white.opacity(0.7), location: 0.5),
                                     .init(color: .white.opacity(0), location: 1)]),
                    startPoint: CGPoint(x: centerX, y: 0), endPoint: CGPoint(x: centerX, y: h)))
    }

    /// Band color from the stored continuous RGB, mixed 18% toward white — the plugin's COLOR_WHITE_MIX,
    /// applied to the close-up only (the overview keeps the raw band color).
    static func scopeColor(_ b: StereoWaveBin) -> Color {
        let mix: Float = 0.18
        return Color(.sRGB,
                     red: Double(b.r + (1 - b.r) * mix),
                     green: Double(b.g + (1 - b.g) * mix),
                     blue: Double(b.b + (1 - b.b) * mix), opacity: 1)
    }
}

/// Pure time→bar-index math for the close-up (testable without a view). `barsPerSec` is derived from
/// the actual cached density, so short tracks map correctly without assuming a constant.
enum CloseUpMath {
    /// Fractional bar index at the playhead for a sample-accurate `centerTime` (seconds).
    static func playIndex(centerTime: Double, binCount: Int, duration: Double) -> Double {
        guard duration > 0, binCount > 0 else { return 0 }
        let barsPerSec = Double(binCount) / duration
        return max(0, centerTime) * barsPerSec
    }
}

/// Smooth scroll clock for the close-up — a direct port of the plugin's "subway-sign" model
/// (apps/nano-plugin/src/module/waveform/mod.rs + `nano_dsp::waveform::consume_samples`). The audio
/// sample clock (`AudioEngine.centerTime`) only advances once per audio render cycle, so reading it per
/// frame staircases the motion. Instead the playhead advances a frame-counted amount per vsync tick at a
/// reservoir-controlled RATE: the audio↔display clock drift is absorbed into that rate (a gentle slew that
/// holds the playhead a small fixed latency behind the rendered clock), never into the motion — which stays
/// forward-only and uniform. No per-frame clock delta, no float "current time" feeding the position (the
/// hard-won lesson from the plugin). A reference type in `@State` so per-frame state survives view
/// re-evaluation without triggering any SwiftUI invalidation.
final class ScrollClock {
    private var pres = 0.0          // displayed playhead time (s) — only ever advanced, never set from a clock
    private var rate = 0.0          // EMA of audio advance per frame (s/frame): the smooth nominal scroll rate
    private var lastAudio = 0.0
    private var lastFrame = 0.0     // last timeline date → advance once per genuinely new frame
    private var seeded = false

    private let seedRate = 1.0 / 60.0  // nominal per-frame advance to start at, so motion never freezes while the
                                       // rate EMA warms up (the plugin seeds its rate to the first arrival, not 0)
    private let rateBeta = 0.05     // EMA weight for the per-frame arrival rate
    private let gain = 0.1          // reservoir gain — slews the per-frame advance toward target ("slew, never step")
    private let target = 0.05       // FLOOR on how far the playhead trails the rendered clock; the actual hold settles
                                    // near target + (audio-update interval)/2, i.e. larger when `centerTime` updates coarsely
    private let snapGap = 0.5       // |audio − pres| beyond this ⇒ seek / discontinuity ⇒ snap

    /// `now` = TimelineView frame date, used ONLY to detect a new frame (so parent re-renders between vsync
    /// ticks don't double-advance). `audio` = true sample-clock seconds. Returns the center time to draw.
    func present(now: Double, audio: Double, playing: Bool) -> Double {
        guard playing else { seeded = false; pres = audio; return audio }                 // paused: hold at audio
        guard seeded else { seeded = true; pres = audio; lastAudio = audio; lastFrame = now; rate = seedRate; return audio }
        if now == lastFrame { return pres }                                               // same tick (re-render): hold
        lastFrame = now
        let dAudio = audio - lastAudio
        lastAudio = audio
        if abs(audio - pres) > snapGap { pres = audio; return pres }                       // seek: snap (keep the learned rate)
        rate = rate * (1 - rateBeta) + min(max(0, dAudio), 0.05) * rateBeta                // smooth nominal rate
        let reservoir = audio - pres                                                       // rendered audio ahead of playhead
        pres += max(0, rate + gain * (reservoir - target))                                 // forward-only; drift → rate
        return pres
    }
}
