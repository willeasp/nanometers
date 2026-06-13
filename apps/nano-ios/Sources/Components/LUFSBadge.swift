import SwiftUI

/// Glass-capsule LUFS badge that floats over the overview (handoff §02 NMLufs). Shows the live
/// momentary (M, 400 ms) meter — the `M` prefix marks it as momentary loudness (same capsule/placement).
struct LUFSBadge: View {
    var lufs: Double?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {        // §02 NMLufs badge: [M][value][LUFS]
            Text("M").font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(Theme.text3)
            Text(lufs.map { String(format: "%.1f", $0) } ?? "—")
                .font(Theme.mono(13, .semibold)).tracking(-0.2).monospacedDigit().foregroundStyle(Theme.text)
            Text("LUFS").font(Theme.mono(9, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(Color(hex: 0x14161C).opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}
