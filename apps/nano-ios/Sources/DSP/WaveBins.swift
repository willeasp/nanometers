import SwiftUI

/// Pure helpers over [WaveBin]: downsample the one cached array to a target bar count (max-peak
/// per source range, carrying that bar's color), and bridge a bin's continuous color to SwiftUI.
enum WaveBins {
    /// Max-peak downsample to `target` bars. The same cached array feeds the overview (~150),
    /// the row mini (22), and the mini-player mini — never re-analyzed (handoff §05).
    static func maxDownsample(_ bins: [WaveBin], to target: Int) -> [WaveBin] {
        guard target > 0 else { return [] }
        guard !bins.isEmpty else { return Array(repeating: WaveBin(peak: 0, r: 1, g: 1, b: 1), count: target) }
        if bins.count <= target {
            return (0..<target).map { bins[Int(Double($0) / Double(target) * Double(bins.count))] }
        }
        return (0..<target).map { i in
            let lo = i * bins.count / target
            let hi = max(lo + 1, (i + 1) * bins.count / target)
            return bins[lo..<hi].max(by: { $0.peak < $1.peak }) ?? bins[lo]
        }
    }

    /// The bin's continuous band color (ADR 0001). Do NOT remap to the 4 handoff hex tokens.
    static func color(_ bin: WaveBin) -> Color {
        Color(.sRGB, red: Double(bin.r), green: Double(bin.g), blue: Double(bin.b), opacity: 1)
    }

    /// Coloring-off monochrome: accent for played bars, a dim grey for upcoming.
    static let dimUnplayed = Color(.sRGB, red: 0x3A/255, green: 0x3F/255, blue: 0x4B/255, opacity: 1)
}
