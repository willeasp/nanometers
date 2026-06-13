import SwiftUI

/// DJ-style close-up waveform (handoff §05A / prototype `NMScrollWave`): a ~9 s window of the cached
/// bins scrolling right→left past a FIXED center playhead. Pure: it windows the same cached `[WaveBin]`
/// the overview uses (never re-analyzed) and reuses the continuous `WaveBins.color`; the played side
/// dims to 0.42 and both edges fade out. The playhead is advanced by `ScrollClock` (below) — the plugin's
/// "subway-sign" model: a frame-counted, reservoir-controlled step once per `TimelineView` vsync tick
/// whose RATE slews toward the sample-accurate `centerTime`, rather than reading the clock straight into
/// the position each frame (which staircases to the audio render cadence — the "low FPS" look this view
/// was rebuilt to avoid).
struct CloseUpWaveform: View {
    var bins: [WaveBin]
    var currentTime: () -> Double      // the audio sample clock (seconds) the ScrollClock slews its rate toward
    var duration: Double
    var coloringOn: Bool = true
    var isPlaying: Bool
    /// Observed seek/elapsed value (pass `engine.elapsed`). While PAUSED the `TimelineView` schedule is
    /// frozen and `ScrollClock` holds at `currentTime()`, so this value changing on a scrub is what forces
    /// a re-render to re-center the held playhead (handoff §05: a scrub re-centers the close-up even when
    /// paused). Not read in `draw` — its change alone re-renders the view.
    var redrawTrigger: Double
    var height: CGFloat = 56           // §05: 56pt strip

    private let secVisible: CGFloat = 9
    @State private var clock = ScrollClock()

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { timeline in
            Canvas { ctx, size in
                // Scroll by a frame-COUNTED step, never by sampling a clock per frame. `centerTime` only
                // advances once per audio render cycle (tens of ms), so reading it each frame staircases the
                // motion — the Canvas redraws at 60 Hz but the position moves ~12–47×/s ("low FPS"). Instead
                // `clock` advances the playhead a smooth, reservoir-controlled amount once per vsync tick and
                // absorbs audio↔display clock drift into the RATE, never the motion (forward-only — never a
                // backward correction). This is the plugin's "subway-sign" scroll + `consume_samples` law
                // (apps/nano-plugin/src/module/waveform, nano_dsp::waveform). `timeline.date` is used ONLY to
                // tell a genuine new frame from a parent-driven re-render between ticks.
                let now = timeline.date.timeIntervalSinceReferenceDate
                let center = clock.present(now: now, audio: currentTime(), playing: isPlaying)
                draw(ctx, size, center: center)
            }
        }
        .frame(height: height)
        .background(.white.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.white.opacity(0.07), lineWidth: 0.5))
        .overlay(alignment: .topLeading) {
            Text("CLOSE-UP").font(Theme.mono(8.5, .semibold)).tracking(1.4)
                .foregroundStyle(.white.opacity(0.42)).padding(.top, 7).padding(.leading, 10)  // §05 left:10 top:7
        }
        .accessibilityElement()
        .accessibilityIdentifier("closeUpWaveform")
    }

    private func draw(_ ctx: GraphicsContext, _ size: CGSize, center: Double) {
        guard !bins.isEmpty, duration > 0 else { return }
        let w = size.width, h = size.height
        let barsPerSec = Double(bins.count) / duration
        let playIdx = CloseUpMath.playIndex(centerTime: center, binCount: bins.count, duration: duration)
        let pxPerBar = (w / secVisible) / CGFloat(barsPerSec)
        guard pxPerBar > 0 else { return }
        let centerX = w / 2, centerY = h / 2
        let bw = max(1.4, pxPerBar * 0.6)
        let span = Int((Double(centerX / pxPerBar)).rounded(.up)) + 2
        let lo = max(0, Int(playIdx.rounded(.down)) - span)
        let hi = min(bins.count, Int(playIdx.rounded(.up)) + span)
        guard lo < hi else { return }

        for i in lo..<hi {
            let b = bins[i]
            let x = centerX + CGFloat(Double(i) - playIdx) * pxPerBar
            if x < -3 || x > w + 3 { continue }
            let bh = max(2, CGFloat(b.peak) * (h - 6))
            let played = Double(i) < playIdx
            let edge = min(1, (centerX - abs(x - centerX)) / (w * 0.14))     // §05 edge fade
            let alpha = (played ? 0.42 : 1.0) * Double(max(0, edge))
            let base = coloringOn ? WaveBins.color(b) : Theme.accent
            let rect = CGRect(x: x - bw / 2, y: centerY - bh / 2, width: bw, height: bh)
            ctx.fill(Path(roundedRect: rect, cornerRadius: min(bw / 2, 1.6)), with: .color(base.opacity(alpha)))
        }

        // Fixed center playhead: 2pt line + 2.6pt cap dots (§05 / NMScrollWave).
        ctx.fill(Path(CGRect(x: centerX - 1, y: 1, width: 2, height: h - 2)), with: .color(.white.opacity(0.92)))
        ctx.fill(Path(ellipseIn: CGRect(x: centerX - 2.6, y: 4 - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
        ctx.fill(Path(ellipseIn: CGRect(x: centerX - 2.6, y: h - 4 - 2.6, width: 5.2, height: 5.2)), with: .color(.white))
    }
}

/// Pure time→bar-index math for the close-up (testable without a view). `barsPerSec` is derived from
/// the actual cached density (handoff: ~7/sec target; cache is 10/sec), so short tracks (floored at
/// 150 bins) map correctly without assuming a constant.
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
