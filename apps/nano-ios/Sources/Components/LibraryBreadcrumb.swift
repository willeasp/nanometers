import SwiftUI

/// Back chevron + tappable mono breadcrumb trail. The last crumb is plain text; all others are
/// buttons. `onCrumb` receives the `folderDepth` of the tapped crumb (caller maps to nav).
struct LibraryBreadcrumb: View {
    let crumbs: [BrowseContent.Crumb]
    var onCrumb: (Int) -> Void = { _ in }
    var onBack: () -> Void = {}

    var body: some View {
        HStack(spacing: 0) {
            // Back chevron button
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(Theme.sans(16, .semibold))
                    .foregroundStyle(Theme.accent)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)

            // Crumbs joined by " / "
            HStack(spacing: 0) {
                ForEach(Array(crumbs.enumerated()), id: \.offset) { idx, crumb in
                    let isLast = idx == crumbs.count - 1
                    if idx > 0 {
                        Text(" / ")
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.text3)
                    }
                    if isLast {
                        Text(crumb.label)
                            .font(Theme.mono(11))
                            .foregroundStyle(Theme.text2)
                    } else {
                        Button(crumb.label) {
                            onCrumb(crumb.folderDepth)
                        }
                        .buttonStyle(.plain)
                        .font(Theme.mono(11))
                        .foregroundStyle(Theme.accent.opacity(0.8))
                        .accessibilityIdentifier("crumb-\(crumb.label)")
                    }
                }
            }
            .lineLimit(1)

            Spacer(minLength: 0)
        }
        .accessibilityIdentifier("breadcrumb")
    }
}
