import SwiftUI

/// Full-track overview waveform (handoff §02 NMWaveform): ~150 vertical bars, played bars full
/// color, upcoming bars 20% alpha, a 2pt white playhead with a soft glow, and whole-strip scrub
/// (drag anywhere → x → fraction → onScrub). Pure: bins + progress + onScrub, no engine — so
/// Phase 4 re-hosts it on Now Playing unchanged.
struct OverviewWaveform: View {
    var bins: [WaveBin]
    var progress: Double
    var coloringOn: Bool = true
    var onScrub: (Double) -> Void

    var bars: Int = 150
    var height: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { ctx, size in
                guard !bins.isEmpty else { return }
                let bars = WaveBins.maxDownsample(bins, to: bars)
                let slot = size.width / CGFloat(bars.count)
                let barW = slot * 0.66
                let playedX = size.width * CGFloat(min(1, max(0, progress)))
                for (i, b) in bars.enumerated() {
                    let h = max(2, CGFloat(b.peak) * (size.height - 4))
                    let x = CGFloat(i) * slot + (slot - barW) / 2
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                    let played = (x + barW) <= playedX
                    let base = coloringOn ? WaveBins.color(b) : Theme.accent
                    let color = played ? base : base.opacity(0.20)   // upcoming 20% (handoff §02)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                }
                var head = Path()
                head.move(to: CGPoint(x: playedX, y: 0)); head.addLine(to: CGPoint(x: playedX, y: size.height))
                ctx.addFilter(.shadow(color: .white.opacity(0.6), radius: 4))
                ctx.stroke(head, with: .color(.white), lineWidth: 2)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    onScrub(min(1, max(0, v.location.x / width)))
                }
            )
            .accessibilityIdentifier("overviewWaveform")
        }
        .frame(height: height)
    }
}
