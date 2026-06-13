import SwiftUI

/// A Library-root row for a connected Source: tinted 46pt tile, label, folder/track counts,
/// status dot, and a chevron. Mirrors the NMRow height so the root list looks cohesive.
struct SourceRow: View {
    let source: Source
    var counts: LibraryIndex.Counts = .init()
    var onTap: () -> Void = {}

    private var kind: SourceKind { SourceKind(rawValue: source.kind) ?? .local }
    private var state: SourceState { SourceState(rawValue: source.state) ?? .offline }

    var body: some View {
        HStack(spacing: 12) {
            // 46pt tinted tile with the source glyph (matches NMRow artwork size)
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous)
                    .fill(Color(hex: source.tintHex).opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: kind.sfSymbol)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: source.tintHex))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(source.label)
                    .font(Theme.sans(16, .medium))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            // Status dot
            Circle()
                .fill(state.dotColor)
                .frame(width: 7, height: 7)

            Image(systemName: "chevron.right")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.text3)
        }
        .frame(minHeight: Theme.Layout.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityIdentifier("sourceRow-\(source.id)")
    }

    private var subtitleText: String {
        let f = counts.folders, t = counts.tracks
        if f == 0 { return "\(t) tracks" }
        return "\(f) folders · \(t) tracks"
    }
}

// MARK: - Helpers

private extension SourceKind {
    var sfSymbol: String {
        switch self {
        case .local:    "iphone"
        case .icloud:   "icloud"
        case .gdrive:   "cloud"
        case .onedrive: "cloud"
        case .dropbox:  "shippingbox"
        }
    }
}

private extension SourceState {
    var dotColor: Color {
        switch self {
        case .connected:  Color(hex: "#4ADE80")   // green
        case .needsReauth: Color(hex: "#FBBF24")  // amber
        default:          Theme.text3              // grey
        }
    }
}
