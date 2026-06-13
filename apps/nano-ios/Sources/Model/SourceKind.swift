import Foundation

/// Where a track's file lives. Only `.local` is exercised in Phase 1; cloud providers are a v2 cut
/// (handoff §04). Stored as the raw string on `Track.sourceKind`.
enum SourceKind: String, CaseIterable {
    case local, icloud, gdrive, onedrive, dropbox
    var label: String {
        switch self {
        case .local: "On My iPhone"
        case .icloud: "iCloud Drive"
        case .gdrive: "Google Drive"
        case .onedrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }

    /// Abbreviated name for breadcrumbs / first crumb (handoff §3.2).
    var short: String {
        switch self {
        case .local: "iPhone"
        case .icloud: "iCloud"
        case .gdrive: "Drive"
        case .onedrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }

    /// Per-source tint for icon tiles / folder glyphs (handoff §01).
    var tintHex: String {
        switch self {
        case .local: "#B990F5"
        case .icloud: "#5EC8C0"
        case .gdrive: "#6FCF72"
        case .dropbox: "#6AA6FF"
        case .onedrive: "#8AB4F8"
        }
    }

    /// Fixed Library-root order, independent of connection order (handoff §3.1).
    var canonicalOrder: Int {
        switch self {
        case .local: 0
        case .icloud: 1
        case .gdrive: 2
        case .dropbox: 3
        case .onedrive: 4
        }
    }
}
