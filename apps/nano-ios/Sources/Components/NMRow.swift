import SwiftUI

struct NMRow: View {
    let track: Track
    var isCurrent: Bool = false
    var onEllipsis: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            NMArtwork(data: track.artworkData, size: 46, radius: Theme.Radius.albumRow)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Theme.sans(16, .medium))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text(track.artist).foregroundStyle(Theme.text2)
                    if !track.album.isEmpty {
                        Text(" · \(track.album)").foregroundStyle(Theme.text3)
                    }
                }
                .font(Theme.sans(13.5))
                .lineLimit(1)
            }
            Spacer(minLength: 8)

            // Phase 3 fills these: a 42×20 mini-waveform and the per-track LUFS (mono, tabular).
            // Left intentionally empty in the shell.

            Button(action: onEllipsis) {
                Image(systemName: "ellipsis")
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 34, height: 44)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: Theme.Layout.rowMinHeight)
        .contentShape(Rectangle())
    }
}
