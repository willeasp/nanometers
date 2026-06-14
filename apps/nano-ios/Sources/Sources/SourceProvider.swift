import Foundation

/// A node discovered by enumerating a source: a folder (with children) or a track (a playable file).
struct FolderDescriptor: Equatable {
    var id: String            // provider folder id (cloud) or a stable derived id (local: hashed path)
    var name: String
    var parentId: String?
    var childFolderIds: [String]
    var trackIds: [String]    // provider file ids of the folder's direct tracks
}
struct TrackDescriptor: Equatable {
    var id: String            // provider file id (cloud) or derived id (local: hashed path)
    var title: String, artist: String, album: String
    var durationSec: Double
    var format: String
    var bookmark: Data?       // local: per-file security-scoped bookmark (nil for cloud)
    var providerFileId: String?  // cloud file id (nil for local)
}
struct EnumerationResult: Equatable { var folders: [FolderDescriptor]; var tracks: [TrackDescriptor] }

/// Abstracts a storage provider so the Library/index/Settings are source-agnostic (handoff §08/§09).
/// Local/iCloud + (Phase 5) Google Drive each implement this.
protocol SourceProvider {
    var kind: SourceKind { get }
    /// Enumerate a root's full subtree into descriptors. `rootId` is the RootFolder's nodeId/providerFolderId.
    func enumerate(rootBookmark: Data?, providerFolderId: String?, rootName: String, rootId: String) async throws -> EnumerationResult
}
