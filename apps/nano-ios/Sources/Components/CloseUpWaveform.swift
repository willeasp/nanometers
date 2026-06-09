import SwiftUI

/// DJ-style close-up waveform (handoff §05A / prototype `NMScrollWave`): a ~9 s window of the cached
/// bins scrolling right→left past a FIXED center playhead, driven by the sample-accurate `centerTime`.
/// Pure: it windows the same cached `[WaveBin]` the overview uses (never re-analyzed), reuses the
/// continuous `WaveBins.color`, and is paced by `TimelineView(.animation)` reading the engine clock
/// each frame (not a wall-clock interpolation). The played side dims to 0.42; both edges fade out.
struct CloseUpWaveform: View {
    var bins: [WaveBin]
    var currentTime: () -> Double      // sample-accurate seconds, read fresh each animated frame
    var duration: Double
    var coloringOn: Bool = true
    var isPlaying: Bool
    /// Observed seek/elapsed value (pass `engine.elapsed`). While playing, `TimelineView` animates off
    /// the live `currentTime()` clock; while PAUSED the schedule is frozen, so this value changing on a
    /// scrub is what forces a re-render to re-center the held frame (handoff §05: a scrub re-centers the
    /// close-up even when paused). Not read in `draw` — its change alone re-renders the view.
    var redrawTrigger: Double
    var height: CGFloat = 56           // §05: 56pt strip

    private let secVisible: CGFloat = 9

    var body: some View {
        TimelineView(.animation(paused: !isPlaying)) { _ in
            Canvas { ctx, size in draw(ctx, size, center: currentTime()) }
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
