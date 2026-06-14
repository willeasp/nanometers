import Foundation
import SwiftData

/// Connect / add-root / remove-root / disconnect over the SwiftData store, then rebuild the index. The
/// picker + enumeration are done by the caller (provider); this turns their output into rows (handoff §06/§08).
@MainActor
final class SourcesManager {
    private let ctx: ModelContext
    private let index: LibraryIndex
    /// In-flight refresh tasks keyed by account name; prevents concurrent double-refresh for the same token.
    private var refreshTasks: [String: Task<OAuthToken, Error>] = [:]
    init(ctx: ModelContext, index: LibraryIndex) { self.ctx = ctx; self.index = index }

    /// Create the Source row (state .noRoots until a root is added).
    func connect(kind: SourceKind, authRef: String? = nil) {
        if (try? LibraryStore.source(id: kind.rawValue, ctx)) ?? nil != nil { return }
        ctx.insert(Source(id: kind.rawValue, kind: kind, state: .noRoots, authRef: authRef))
        index.rebuild(from: ctx)
    }

    /// Materialize an enumeration into FolderNode/Track rows under a new RootFolder, then rebuild.
    /// Upserts Tracks keyed on (sourceId, providerFileId) — re-adding the same root produces no
    /// duplicate Track rows, making the operation idempotent (FIX 3).
    func applyEnumeration(_ result: EnumerationResult, sourceId: String, rootName: String,
                          rootNodeId: String, rootBookmark: Data?, providerFolderId: String? = nil) {
        let kind = SourceKind(rawValue: ((try? LibraryStore.source(id: sourceId, ctx)) ?? nil)?.kind ?? "") ?? .local

        // Build a lookup of existing tracks by (sourceId, providerFileId) for upsert.
        let existingTracks = (try? LibraryStore.allTracksUnsorted(ctx)) ?? []
        var existingByKey: [String: Track] = [:]
        for t in existingTracks {
            guard let sid = t.sourceId, let pfid = t.providerFileId, sid == sourceId else { continue }
            existingByKey[pfid] = t
        }

        // Upsert: reuse an existing Track row if (sourceId, providerFileId) matches; insert otherwise.
        var idMap: [String: UUID] = [:]
        for td in result.tracks {
            let pfid = td.providerFileId ?? td.id
            if let existing = existingByKey[pfid] {
                // Update mutable metadata but keep the existing UUID so playlist refs stay valid.
                existing.title = td.title
                existing.artist = td.artist
                existing.album = td.album
                existing.format = td.format
                existing.durationSec = td.durationSec
                existing.folderBookmark = rootBookmark
                existing.providerFileId = pfid
                idMap[td.id] = existing.id
            } else {
                let t = Track(title: td.title, artist: td.artist, album: td.album,
                              sourceKind: kind.rawValue, bookmark: td.bookmark,
                              folderBookmark: rootBookmark, displayPath: kind.label,
                              durationSec: td.durationSec, format: td.format,
                              sourceId: sourceId, providerFileId: pfid)
                ctx.insert(t)
                idMap[td.id] = t.id
            }
        }
        for fd in result.folders {
            // Upsert FolderNode too: if a node with this id already exists (from a prior enumeration
            // of the same root), update it in place to avoid duplicate nodes.
            if let existing = try? LibraryStore.folderNode(id: fd.id, ctx) {
                existing.name = fd.name
                existing.parentId = fd.parentId
                existing.childFolderIds = fd.childFolderIds
                existing.trackIds = fd.trackIds.compactMap { idMap[$0] }
                existing.lastIndexed = .init()
            } else {
                let node = FolderNode(id: fd.id, sourceId: sourceId, name: fd.name, parentId: fd.parentId,
                                      childFolderIds: fd.childFolderIds,
                                      trackIds: fd.trackIds.compactMap { idMap[$0] }, lastIndexed: .init())
                ctx.insert(node)
            }
            for tid in fd.trackIds {
                if let uuid = idMap[tid], let tr = try? LibraryStore.track(id: uuid, ctx) {
                    tr.folderId = fd.id
                }
            }
        }
        // Only insert a new RootFolder if one for this root doesn't already exist.
        let existingRoots = (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? []
        let rootAlreadyExists = existingRoots.contains {
            ($0.providerFolderId ?? $0.nodeId) == (providerFolderId ?? rootNodeId)
        }
        if !rootAlreadyExists {
            ctx.insert(RootFolder(sourceId: sourceId, name: rootName, providerFolderId: providerFolderId,
                                  nodeId: rootNodeId, bookmark: rootBookmark))
        }
        if let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil {
            s.state = SourceState.connected.rawValue
        }
        index.rebuild(from: ctx)
    }

    func removeRoot(_ root: RootFolder) {
        let sourceId = root.sourceId
        if let nodeId = root.providerFolderId ?? root.nodeId { deleteSubtree(nodeId: nodeId, sourceId: sourceId) }
        ctx.delete(root)
        // If that was the last root, mark the source noRoots.
        if (try? LibraryStore.rootFolders(of: sourceId, ctx))?.isEmpty ?? true,
           let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil {
            s.state = SourceState.noRoots.rawValue
        }
        index.rebuild(from: ctx)
    }

    func disconnect(sourceId: String) {
        for root in (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? [] {
            if let nodeId = root.providerFolderId ?? root.nodeId { deleteSubtree(nodeId: nodeId, sourceId: sourceId) }
            ctx.delete(root)
        }
        if let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil { ctx.delete(s) }
        index.rebuild(from: ctx)
    }

    // MARK: - Provider registry (Task 11)

    /// Returns the `SourceProvider` for `kind`, injecting `accessToken` for cloud providers.
    /// Local/iCloud providers ignore `accessToken` (they use security-scoped bookmarks instead).
    func provider(for kind: SourceKind,
                  accessToken: @escaping () async throws -> String) -> any SourceProvider {
        switch kind {
        case .local, .icloud:
            return LocalSourceProvider(kind: kind)
        case .gdrive:
            return GoogleDriveProvider(api: DriveAPIClient(http: URLSessionHTTPClient()),
                                       accessToken: accessToken)
        case .onedrive, .dropbox:
            // Future providers — fall back to a no-op local provider stub.
            return LocalSourceProvider(kind: .local)
        }
    }

    // MARK: - OAuth (Task 8)

    /// Full OAuth Authorization-Code + PKCE flow for a cloud source (handoff §08.2).
    /// Generates PKCE + state → browser consent → token exchange → Keychain save → connect.
    func connectOAuth(kind: SourceKind,
                      config: OAuthConfig,
                      web: WebAuthSession,
                      client: OAuthClient,
                      tokenStore: TokenStore) async throws {
        let pkce = PKCE.generate()
        let state = PKCE.randomState()
        let authURL = client.authorizeURL(challenge: pkce.challenge, state: state,
                                          redirectURI: config.redirectURI)
        let code = try await web.authorize(url: authURL, callbackScheme: config.redirectScheme,
                                           expectedState: state)
        let token = try await client.exchange(code: code, verifier: pkce.verifier,
                                              redirectURI: config.redirectURI)
        let account = kind.rawValue
        try tokenStore.save(token, account: account)
        connect(kind: kind, authRef: account)
    }

    /// Returns a valid access token for `kind`, refreshing via `client` if the stored token is
    /// within 60 s of expiry. Serializes concurrent refreshes (only one network call per account
    /// at a time; subsequent callers await the same Task).
    func accessToken(for kind: SourceKind,
                     config: OAuthConfig,
                     client: OAuthClient,
                     tokenStore: TokenStore) async throws -> String {
        let account = kind.rawValue
        guard let token = try tokenStore.load(account: account) else {
            throw NSError(domain: "SourcesManager", code: 401,
                          userInfo: [NSLocalizedDescriptionKey: "No stored token for \(account)"])
        }
        // Fast path: token is fresh enough.
        guard token.isExpiring(skew: 60), let refreshToken = token.refreshToken else {
            return token.accessToken
        }
        // Coalesce concurrent refresh calls: if one is already in flight, await it.
        if let existing = refreshTasks[account] {
            let refreshed = try await existing.value
            return refreshed.accessToken
        }
        let task = Task<OAuthToken, Error> { [weak self] in
            let refreshed = try await client.refresh(refreshToken: refreshToken)
            try tokenStore.save(refreshed, account: account)
            await MainActor.run { self?.refreshTasks[account] = nil }
            return refreshed
        }
        refreshTasks[account] = task
        let refreshed = try await task.value
        return refreshed.accessToken
    }

    /// Delete a root's FolderNode subtree (the cache). Track ROWS are kept (playlists may reference them);
    /// they just stop being reachable once their nodes/source are gone.
    private func deleteSubtree(nodeId: String, sourceId: String) {
        guard let node = try? LibraryStore.folderNode(id: nodeId, ctx) else { return }
        for childId in node.childFolderIds { deleteSubtree(nodeId: childId, sourceId: sourceId) }
        ctx.delete(node)
    }
}
