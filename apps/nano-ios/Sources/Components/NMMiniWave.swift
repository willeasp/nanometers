import SwiftUI

/// Static mini waveform (handoff §02): a small N-bar Canvas with no playhead, no scrub. Used at
/// 42×20 in rows (opacity 0.7) and 56×22 in the mini player (accent-tinted). Renders nothing until
/// bins exist.
struct NMMiniWave: View {
    var bins: [WaveBin]
    var bars: Int = 22
    var colored: Bool = true
    var tint: Color = Theme.accent

    var body: some View {
        Canvas { ctx, size in
            guard !bins.isEmpty else { return }
            let bars = WaveBins.maxDownsample(bins, to: bars)
            let slot = size.width / CGFloat(bars.count)
            let barW = slot * 0.66                      // ~34% gap (handoff §02)
            for (i, b) in bars.enumerated() {
                let h = max(2, CGFloat(b.peak) * (size.height - 2))
                let x = CGFloat(i) * slot + (slot - barW) / 2
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                let color = colored ? WaveBins.color(b) : tint
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
    }
}
