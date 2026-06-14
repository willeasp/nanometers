import Foundation

/// Enumerates a OneDrive subtree into provider-agnostic descriptors, mirroring `GoogleDriveProvider`
/// over Microsoft Graph (handoff §08.5). `accessToken` is supplied by the caller (SourcesManager
/// refreshes via OAuthClient), so this stays testable with a static token.
///
/// The `accessToken` closure accepts a `forceRefresh: Bool`. Passing `false` returns the cached /
/// just-refreshed token; passing `true` forces a new refresh POST. This lets `walk` implement a
/// single 401 → forced-refresh → retry cycle.
struct OneDriveProvider: SourceProvider {
    var kind: SourceKind { .onedrive }
    let api: GraphAPIClient
    /// `(_ forceRefresh: Bool) async throws -> String`
    let accessToken: (_ forceRefresh: Bool) async throws -> String

    func enumerate(rootBookmark: Data?, providerFolderId: String?, rootName: String, rootId: String) async throws -> EnumerationResult {
        var folders: [FolderDescriptor] = []; var tracks: [TrackDescriptor] = []
        var visited = Set<String>()
        try await walk(folderId: rootId, name: rootName, parentId: nil, depth: 0,
                       visited: &visited, folders: &folders, tracks: &tracks)
        return EnumerationResult(folders: folders, tracks: tracks)
    }

    private func walk(folderId: String, name: String, parentId: String?, depth: Int,
                      visited: inout Set<String>,
                      folders: inout [FolderDescriptor], tracks: inout [TrackDescriptor]) async throws {
        guard visited.insert(folderId).inserted else { return }   // cycle / multi-parent — skip duplicate
        guard depth <= 64 else { return }                          // depth backstop (shortcuts-to-ancestor)

        let token = try await accessToken(false)
        let (subFolders, subTracks): ([GraphItem], [GraphItem])
        do {
            (subFolders, subTracks) = try await api.listChildren(parentId: folderId, accessToken: token)
        } catch GraphError.unauthorized {
            // Token expired mid-enumeration → force a single refresh and retry once.
            let fresh = try await accessToken(true)
            (subFolders, subTracks) = try await api.listChildren(parentId: folderId, accessToken: fresh)
        }

        var childIds: [String] = []; var trackIds: [String] = []
        for f in subFolders { childIds.append(f.id) }
        for t in subTracks {
            trackIds.append(t.id)
            tracks.append(TrackDescriptor(id: t.id, title: (t.name as NSString).deletingPathExtension, artist: "",
                                          album: "", durationSec: 0, format: (t.name as NSString).pathExtension.uppercased(),
                                          bookmark: nil, providerFileId: t.id))
        }
        folders.append(FolderDescriptor(id: folderId, name: name, parentId: parentId, childFolderIds: childIds, trackIds: trackIds))
        for f in subFolders {
            try await walk(folderId: f.id, name: f.name, parentId: folderId, depth: depth + 1,
                           visited: &visited, folders: &folders, tracks: &tracks)
        }
    }
}
