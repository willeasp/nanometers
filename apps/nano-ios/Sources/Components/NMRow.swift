import SwiftUI

struct NMRow: View {
    let track: Track
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var onTap: () -> Void = {}
    var onEllipsis: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            NMArtwork(data: track.artworkData, size: 46, radius: Theme.Radius.albumRow)
                .overlay {
                    if isCurrent {
                        ZStack {
                            Color.black.opacity(0.45)
                            Image(systemName: isPlaying ? "waveform" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous))
                    }
                }

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
        .onTapGesture { onTap() }
    }
}
