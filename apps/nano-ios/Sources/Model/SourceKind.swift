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
}
