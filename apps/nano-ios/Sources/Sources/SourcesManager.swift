import Foundation
import SwiftData

/// Connect / add-root / remove-root / disconnect over the SwiftData store, then rebuild the index. The
/// picker + enumeration are done by the caller (provider); this turns their output into rows (handoff §06/§08).
@MainActor
final class SourcesManager {
    private let ctx: ModelContext
    private let index: LibraryIndex
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

    /// Disconnect a source: best-effort revoke the OAuth token (network failure is ignored), delete
    /// the Keychain credential, then delete the Source row + its root subtree (handoff §8.3 / spec §14).
    ///
    /// Pass `tokenStore` and `http` only for cloud sources that have an `authRef`. The caller in
    /// SourceDetailView passes real implementations; tests pass in-memory stubs.
    func disconnect(sourceId: String,
                    tokenStore: (any TokenStore)? = nil,
                    http: (any HTTPClient)? = nil) {
        // Best-effort: revoke + delete Keychain token before removing the row.
        if let tokenStore, let source = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil,
           source.authRef != nil,
           let stored = try? tokenStore.load(account: sourceId) {
            // Fire-and-forget revoke POST (ignore failure — local delete always proceeds). Only Google
            // exposes a standard OAuth revocation endpoint; Microsoft's /consumers authority has none, so
            // for OneDrive we'd just be shipping a (rotated) Microsoft refresh token to Google's endpoint
            // for a guaranteed no-op. Revoke only for Drive; other providers' tokens expire/rotate server-
            // side on their own once the local Keychain credential is dropped below.
            if SourceKind(rawValue: source.kind) == .gdrive, let http {
                let revokeToken = stored.refreshToken ?? stored.accessToken
                Task.detached {
                    _ = try? await Self.revokeToken(revokeToken, http: http)
                }
            }
            try? tokenStore.delete(account: sourceId)
        }
        for root in (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? [] {
            if let nodeId = root.providerFolderId ?? root.nodeId { deleteSubtree(nodeId: nodeId, sourceId: sourceId) }
            ctx.delete(root)
        }
        if let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil { ctx.delete(s) }
        index.rebuild(from: ctx)
    }

    /// POST https://oauth2.googleapis.com/revoke?token=<token> — best-effort, result ignored by callers.
    /// Google-specific: only `disconnect` for `.gdrive` calls this (Microsoft has no equivalent endpoint).
    private static func revokeToken(_ token: String, http: any HTTPClient) async throws {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/revoke")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("token=\(token)".utf8)
        _ = try await http.send(req)
    }

    // MARK: - Provider registry (Task 11)

    /// Returns the `SourceProvider` for `kind`, injecting `accessToken` for cloud providers.
    /// Local/iCloud providers ignore `accessToken` (they use security-scoped bookmarks instead).
    func provider(for kind: SourceKind,
                  accessToken: @escaping (_ forceRefresh: Bool) async throws -> String) -> any SourceProvider {
        switch kind {
        case .local, .icloud:
            return LocalSourceProvider(kind: kind)
        case .gdrive:
            return GoogleDriveProvider(api: DriveAPIClient(http: URLSessionHTTPClient()),
                                       accessToken: accessToken)
        case .onedrive:
            return OneDriveProvider(api: GraphAPIClient(http: URLSessionHTTPClient()), accessToken: accessToken)
        case .dropbox:
            // Future provider — unreachable while the UI gates Dropbox as "Coming soon".
            // Fail loudly so a future caller doesn't silently get a no-op local provider.
            assertionFailure("provider(for:) called for unsupported provider '\(kind.rawValue)'")
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
        // Fresh source → create it; existing source (e.g. a Reconnect from .needsReauth) → connect() would
        // no-op, so restore its state here (FIX: needsReauth was a one-way trap).
        if (try? LibraryStore.source(id: account, ctx)) ?? nil != nil {
            markReachable(account)
        } else {
            connect(kind: kind, authRef: account)
        }
    }

    /// Restore a degraded (`.needsReauth` / `.offline`) source to a healthy state after a successful
    /// auth or token refresh: `.connected` if it has roots, else `.noRoots`. No-op when already healthy.
    private func markReachable(_ sourceId: String) {
        guard let s = (try? LibraryStore.source(id: sourceId, ctx)) ?? nil else { return }
        let state = SourceState(rawValue: s.state)
        guard state == .needsReauth || state == .offline else { return }
        let hasRoots = !((try? LibraryStore.rootFolders(of: sourceId, ctx))?.isEmpty ?? true)
        s.state = (hasRoots ? SourceState.connected : SourceState.noRoots).rawValue
        index.rebuild(from: ctx)
    }

    /// Returns a valid access token for `kind`, refreshing via the shared `TokenRefreshCoordinator`
    /// if the stored token is within 60 s of expiry. Concurrent callers for the same account are
    /// coalesced into a single refresh POST; the slot clears on both success and failure.
    ///
    /// On refresh failure the source row is flipped to `.needsReauth` (amber dot) before rethrowing,
    /// so the UI reflects that re-authentication is required (handoff §8.3 / spec §14).
    func accessToken(for kind: SourceKind,
                     config: OAuthConfig,
                     client: OAuthClient,
                     tokenStore: any TokenStore,
                     forceRefresh: Bool = false) async throws -> String {
        let account = kind.rawValue
        do {
            let token = try await TokenRefreshCoordinator.shared.validToken(
                account: account, store: tokenStore, client: client, forceRefresh: forceRefresh)
            markReachable(account)   // success after a degraded state → back to connected (FIX: recovery)
            return token.accessToken
        } catch {
            // Classify: a definitive auth failure (no/expired refresh token, invalid_grant) → needsReauth;
            // a transient failure (network offline, timeout) → .offline, which is recoverable and doesn't
            // strand the source amber. Missing-token on first launch is a no-op (source doesn't exist yet).
            if let s = (try? LibraryStore.source(id: account, ctx)) ?? nil {
                s.state = Self.degradedState(for: error).rawValue
                index.rebuild(from: ctx)
            }
            throw error
        }
    }

    /// Map a token-acquisition error to the source state it should leave behind.
    static func degradedState(for error: Error) -> SourceState {
        switch error {
        case OAuthError.noRefreshToken, OAuthError.noStoredToken:
            return .needsReauth
        case let ns as NSError where ns.domain == "OAuth" && (ns.code == 400 || ns.code == 401):
            return .needsReauth   // invalid_grant / unauthorized — the refresh token is dead
        case is URLError:
            return .offline       // network blip — recoverable, don't strand the source
        default:
            return .offline       // unknown → assume transient rather than permanently wedge
        }
    }

    /// Delete a root's FolderNode subtree (the cache). Track ROWS are kept (playlists may reference them);
    /// they just stop being reachable once their nodes/source are gone.
    private func deleteSubtree(nodeId: String, sourceId: String) {
        guard let node = try? LibraryStore.folderNode(id: nodeId, ctx) else { return }
        for childId in node.childFolderIds { deleteSubtree(nodeId: childId, sourceId: sourceId) }
        ctx.delete(node)
    }
}
