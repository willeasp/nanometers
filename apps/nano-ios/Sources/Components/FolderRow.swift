import SwiftUI

/// A folder row inside a source: tinted folder glyph, name, recursive counts, chevron.
/// Used at both source-root level ("Root Folders") and sub-folder level ("Folders").
struct FolderRow: View {
    let name: String
    var tint: String = "#9AA1B0"
    var counts: LibraryIndex.Counts = .init()
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous)
                    .fill(Color(hex: tint).opacity(0.16))
                    .frame(width: 46, height: 46)
                Image(systemName: "folder.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(Color(hex: tint))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(Theme.sans(15, .medium))
                    .tracking(-0.2)
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(subtitleText)
                    .font(Theme.mono(11.5))
                    .foregroundStyle(Theme.text3)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Image(systemName: "chevron.right")
                .font(Theme.sans(13, .semibold))
                .foregroundStyle(Theme.text3)
        }
        .frame(minHeight: Theme.Layout.rowMinHeight)
        .contentShape(Rectangle())
        .onTapGesture { onTap() }
        .accessibilityIdentifier("folderRow-\(name)")
    }

    private var subtitleText: String {
        let f = counts.folders, t = counts.tracks
        if f == 0 { return "\(t) tracks" }
        return "\(f) folders · \(t) tracks"
    }
}
