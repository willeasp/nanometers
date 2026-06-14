import SwiftUI

/// Close-up scope (handoff §06D.1) — the flip card's signature meter. A window of the cached **stereo**
/// bins scrolling right→left past a FIXED center playhead. ONE waveform around a single center line:
/// the **upper half is the LEFT channel, the lower half is the RIGHT** (rectified peak envelope filled
/// from the center), spectrally colored. Uniform brightness (no played/upcoming dimming), a soft
/// edge-fade, and scrub-anywhere-to-seek. The
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
    var active: Bool = true            // flipped && open — no scroll work behind the cover (§06B)
    var onScrub: (Double) -> Void = { _ in }

    @State private var clock = ScrollClock()

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: !(isPlaying && active))) { timeline in
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
        let w = size.width, h = size.height
        guard w > 1, h > 1 else { return }
        let centerX = w / 2

        // whisper-faint center axis (white@5%) at the L/R divider
        ctx.fill(Path(CGRect(x: 0, y: (h / 2).rounded(), width: w, height: 1)), with: .color(.white.opacity(0.05)))

        drawContour(ctx, w: w, h: h, centerX: centerX, center: center)

        // soft center playhead — vertical white gradient (transparent → 0.7 → transparent), §06D.1.
        ctx.fill(Path(CGRect(x: centerX - 1, y: 0, width: 2, height: h)),
                 with: .linearGradient(
                    Gradient(stops: [.init(color: .white.opacity(0), location: 0),
                                     .init(color: .white.opacity(0.7), location: 0.5),
                                     .init(color: .white.opacity(0), location: 1)]),
                    startPoint: CGPoint(x: centerX, y: 0), endPoint: CGPoint(x: centerX, y: h)))
    }

    /// The nano-plugin Waveform look, ported to a scrubbable cache (apps/nano-plugin/src/module/waveform):
    /// each cache bin keeps its own pre-analyzed min/max envelope and is placed at an **affine** x —
    /// `x(i) = centerX + (binTime − center)·pxPerSec`. Only `center` changes frame to frame, so every
    /// bin's x shifts by the SAME delta: the contour rigidly translates left, never re-binning (the old
    /// per-pixel re-aggregation against a sub-pixel offset is what shimmered/"morphed").
    ///
    /// ONE waveform on a SINGLE center line: L is the upper silhouette, R the lower — each the rectified
    /// peak `max(|min|, |max|)` filled from the center. Color is a horizontal spectral gradient with one
    /// stop PER BIN: each stop is anchored to its bin's pixel `x(i)`, so the color rigidly translates with
    /// the contour. (The old ≤64-stop subsample re-bucketed which bins became stops every frame, so the
    /// interpolated color at each fixed pixel drifted — that was the back-and-forth color flicker.)
    private func drawContour(_ ctx: GraphicsContext, w: CGFloat, h: CGFloat, centerX: CGFloat, center: Double) {
        guard bins.count > 1, duration > 0 else { return }
        let binsPerSec = Double(bins.count) / duration
        let pxPerSec = w / CGFloat(max(0.5, windowSec))
        let zero = h / 2                             // single center line: L above, R below
        let halfAmp = (h / 2) * 0.95                 // one-sided from the divider: a ±1 sample fills 95% of the
                                                     // half-lane (5% edge margin), matching the plugin's NDC +0.95
                                                     // outer reach. (The plugin stacks TWO bipolar lanes centered
                                                     // at NDC ±0.5; consolidating to one center line halved the look
                                                     // at 0.45 — amp is clamped to ±1 so 0.95 still can't overflow.)

        // Visible bin window (a one-bin margin so the contour enters/leaves cleanly under the edge fade).
        func binAtX(_ x: CGFloat) -> Double { (center + Double((x - centerX) / pxPerSec)) * binsPerSec }
        let firstBin = max(0, Int(binAtX(0).rounded(.down)) - 1)
        let lastBin = min(bins.count - 1, Int(binAtX(w).rounded(.up)) + 1)
        guard lastBin > firstBin else { return }

        func x(_ i: Int) -> CGFloat { centerX + CGFloat(Double(i) / binsPerSec - center) * pxPerSec }

        // Rectified peak per channel: the upper silhouette is L, the lower is R, hinged on the center.
        func ampL(_ b: StereoWaveBin) -> CGFloat { CGFloat(max(b.lMax, -b.lMin)) }
        func ampR(_ b: StereoWaveBin) -> CGFloat { CGFloat(max(b.rMax, -b.rMin)) }
        func silhouette(up: Bool, _ amp: (StereoWaveBin) -> CGFloat) -> Path {
            var p = Path()
            let sign: CGFloat = up ? -1 : 1
            p.move(to: CGPoint(x: x(firstBin), y: zero))
            for i in firstBin...lastBin { p.addLine(to: CGPoint(x: x(i), y: zero + sign * amp(bins[i]) * halfAmp)) }
            p.addLine(to: CGPoint(x: x(lastBin), y: zero))
            p.closeSubpath()
            return p
        }
        let lPath = silhouette(up: true, ampL)
        let rPath = silhouette(up: false, ampR)

        // Horizontal spectral gradient, ONE stop per visible bin, anchored to the FIXED scope width [0, w] —
        // NOT the visible-bin window [x(firstBin), x(lastBin)]. That window's endpoints step 2–3 bins/frame as
        // it scrolls, so normalizing the stop locations + edge fade against it re-mapped every bin's colour and
        // opacity each frame: the small colour flicker. Pinning to [0, w] keeps each bin's colour + fade put as
        // it scrolls; only the off-screen edge stops (under the ~0-opacity fade) come and go.
        var stops: [Gradient.Stop] = []
        stops.reserveCapacity(lastBin - firstBin + 1)
        var lastLoc: CGFloat = -1
        for i in firstBin...lastBin {
            let loc = min(1, max(0, x(i) / w))
            if loc <= lastLoc { continue }      // Gradient stop locations must be strictly increasing
            lastLoc = loc
            let base = coloringOn ? Self.scopeColor(bins[i]) : Theme.accent
            stops.append(.init(color: base.opacity(edgeAlpha(loc)), location: loc))
        }
        guard stops.count > 1 else { return }
        let shading = GraphicsContext.Shading.linearGradient(
            Gradient(stops: stops), startPoint: CGPoint(x: 0, y: 0), endPoint: CGPoint(x: w, y: 0))
        ctx.fill(lPath, with: shading)
        ctx.fill(rPath, with: shading)
    }

    /// §06 edge fade: full brightness in the middle, easing to transparent within the outer ~10%.
    private func edgeAlpha(_ loc: CGFloat) -> Double {
        let e: CGFloat = 0.10
        return Double(min(1, max(0, min(loc, 1 - loc) / e)))
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
    private let gain = 0.01         // reservoir gain — slews the per-frame advance toward target ("slew, never step").
                                    // Deliberately tiny (cf. the plugin's 0.005): the audio clock only updates once per
                                    // ~21 ms render block, so `reservoir = audio − pres` sawtooths every frame; a large
                                    // gain pumps that sawtooth straight into the MOTION (visible judder). Keeping it tiny
                                    // lets the smoothed `rate` carry the motion and the reservoir only trim slow drift.
    private let target = 0.06       // how far the playhead trails the rendered clock; ≥ one audio block so the sawtooth
                                    // reservoir stays positive (never starves the contour at the edge)
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
