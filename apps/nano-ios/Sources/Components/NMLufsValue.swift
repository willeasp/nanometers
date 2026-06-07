import SwiftUI

/// Per-track integrated LUFS, right-aligned: value 12pt `text2` (mono, tabular, one decimal) over
/// a "LUFS" 9.5pt `text3` label (handoff §02 NMRow item 4). Shows a dash while not yet analyzed.
struct NMLufsValue: View {
    var lufs: Double?
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(lufs.map { String(format: "%.1f", $0) } ?? "—")
                .font(Theme.mono(12)).foregroundStyle(Theme.text2)
            Text("LUFS")
                .font(Theme.mono(9.5)).foregroundStyle(Theme.text3)
        }
    }
}
