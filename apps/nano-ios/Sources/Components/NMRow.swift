import SwiftUI

struct NMRow: View {
    let track: Track
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var isPreparing: Bool = false   // cloud track downloading before playback → show a spinner
    var isAvailable: Bool = true
    var onTap: () -> Void = {}
    var onEllipsis: () -> Void = {}

    @State private var bins: [WaveBin] = []

    var body: some View {
        HStack(spacing: 12) {
            NMArtwork(data: track.artworkData, size: 46, radius: Theme.Radius.albumRow)
                .overlay {
                    if isCurrent || isPreparing {
                        ZStack {
                            Color.black.opacity(0.45)
                            if isPreparing {
                                ProgressView().controlSize(.small).tint(.white)
                            } else {
                                Image(systemName: isPlaying ? "waveform" : "play.fill")
                                    .font(.system(size: 16, weight: .semibold))
                                    .foregroundStyle(.white)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous))
                    }
                }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(track.title)
                        .font(Theme.sans(16, .medium))
                        .tracking(-0.2)                              // §01 row title tracking
                        .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                        .lineLimit(1)
                    if !isAvailable {
                        Text("Unavailable")
                            .font(Theme.sans(10, .medium))
                            .foregroundStyle(Theme.text3)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 2)
                            .background(Theme.text3.opacity(0.18), in: Capsule())
                            .accessibilityIdentifier("unavailableTag")
                    }
                }
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

            if !bins.isEmpty {
                NMMiniWave(bins: bins, bars: 22)
                    .frame(width: 42, height: 20).opacity(0.7)
                    .accessibilityHidden(true)
            }
            NMLufsValue(lufs: track.integratedLUFS)
                .frame(minWidth: 44, alignment: .trailing)

            Button(action: onEllipsis) {
                Image(systemName: "ellipsis")
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 34, height: 44)
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("rowEllipsis")
        }
        .frame(minHeight: Theme.Layout.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { if isAvailable { onTap() } }
        .opacity(isAvailable ? 1 : 0.45)
        // binsTaskID re-runs the fetch once a just-downloaded cloud track is analyzed (key flips "" → hash).
        .task(id: track.binsTaskID) {
            bins = await WaveformStore.shared.bins(for: track) ?? []
        }
    }
}
