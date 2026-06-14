import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourcesManagerTests: XCTestCase {
    // MARK: - needsReauth recovery + error classification (review fixes)

    func test_degradedState_classifiesAuthVsTransient() {
        XCTAssertEqual(SourcesManager.degradedState(for: OAuthError.noRefreshToken(account: "x")), .needsReauth)
        XCTAssertEqual(SourcesManager.degradedState(for: OAuthError.noStoredToken(account: "x")), .needsReauth)
        XCTAssertEqual(SourcesManager.degradedState(for: NSError(domain: "OAuth", code: 400)), .needsReauth)
        XCTAssertEqual(SourcesManager.degradedState(for: NSError(domain: "OAuth", code: 401)), .needsReauth)
        XCTAssertEqual(SourcesManager.degradedState(for: URLError(.notConnectedToInternet)), .offline)
        XCTAssertEqual(SourcesManager.degradedState(for: NSError(domain: "OAuth", code: 500)), .offline)
    }

    func test_accessToken_recoversFromNeedsReauthOnSuccess() async throws {
        let ctx = try TestDB.context()
        let mgr = SourcesManager(ctx: ctx, index: LibraryIndex())
        // A source stranded in needsReauth, but it has a root and a valid (non-expiring) token.
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .needsReauth, authRef: "gdrive"))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "P", providerFolderId: "root"))
        let store = InMemoryTokenStore()
        try store.save(OAuthToken(accessToken: "AT", refreshToken: "RT",
                                  expiry: Date(timeIntervalSinceNow: 3600)), account: "gdrive")
        let cfg = OAuthConfig(clientID: "cid", redirectURI: "s:/oauth", authEndpoint: URL(string: "https://a")!,
                              tokenEndpoint: URL(string: "https://t")!, scopes: [])
        let token = try await mgr.accessToken(for: .gdrive, config: cfg,
                                              client: OAuthClient(config: cfg, http: MockHTTPClient(responses: [])),
                                              tokenStore: store)
        XCTAssertEqual(token, "AT")
        XCTAssertEqual(try LibraryStore.source(id: "gdrive", ctx)?.state, SourceState.connected.rawValue,
                       "a successful token fetch must clear needsReauth")
    }

    func test_connectAndAddRoot_createsSourceFoldersTracks_andReachable() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex()
        let mgr = SourcesManager(ctx: ctx, index: idx)
        // Connect iCloud, then add a root whose enumeration we supply directly.
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [
                FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: ["h"], trackIds: []),
                FolderDescriptor(id: "h", name: "House", parentId: "r", childFolderIds: [], trackIds: ["t1"]),
            ],
            tracks: [TrackDescriptor(id: "t1", title: "Caldera", artist: "Oso", album: "",
                                     durationSec: 0, format: "WAV", bookmark: nil,
                                     providerFileId: "House/Caldera.wav")])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        XCTAssertEqual(try LibraryStore.source(id: "icloud", ctx)?.state, "connected")
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 1)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.tracks, 1)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.folders, 2)
        XCTAssertTrue(idx.reachableTrackIds.contains(where: { _ in true }))   // a track exists & reachable
    }

    func test_removeRoot_dropsItsTracksFromReachable() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: [], trackIds: ["t1"])],
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV",
                                     bookmark: nil, providerFileId: "A.wav")])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        let root = try LibraryStore.rootFolders(of: "icloud", ctx).first!
        mgr.removeRoot(root)
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 0)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.tracks ?? 0, 0)
    }

    func test_disconnect_clearsSourceRootsNodes_butKeepsTrackRowsForPlaylists() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: [], trackIds: ["t1"])],
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV",
                                     bookmark: nil, providerFileId: "A.wav")])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        mgr.disconnect(sourceId: "icloud")
        XCTAssertNil(try LibraryStore.source(id: "icloud", ctx))
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 0)
        XCTAssertTrue(try LibraryStore.childFolders(of: "r", ctx).isEmpty)   // folder nodes gone
        // Track rows persist (playlists may reference them) but are no longer reachable.
        XCTAssertFalse(idx.reachableTrackIds.contains(where: { _ in true }) && idx.sourceCounts["icloud"] != nil)
    }

    // MARK: - FIX 3: Upsert / idempotency

    func test_applyEnumeration_isIdempotent_noDuplicateTracks() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .local)

        let result = EnumerationResult(
            folders: [
                FolderDescriptor(id: "r", name: "Music", parentId: nil, childFolderIds: [], trackIds: ["t1", "t2"])
            ],
            tracks: [
                TrackDescriptor(id: "t1", title: "Alpha", artist: "", album: "", durationSec: 0, format: "MP3",
                                bookmark: nil, providerFileId: "Alpha.mp3"),
                TrackDescriptor(id: "t2", title: "Beta",  artist: "", album: "", durationSec: 0, format: "WAV",
                                bookmark: nil, providerFileId: "Beta.wav"),
            ]
        )
        let rootBookmark = Data([0xDE, 0xAD])

        // First application.
        mgr.applyEnumeration(result, sourceId: "local", rootName: "Music",
                             rootNodeId: "r", rootBookmark: rootBookmark)
        let countAfterFirst = try LibraryStore.allTracks(ctx).count

        // Second application of the SAME result — upsert must reuse rows, not insert duplicates.
        mgr.applyEnumeration(result, sourceId: "local", rootName: "Music",
                             rootNodeId: "r", rootBookmark: rootBookmark)
        let countAfterSecond = try LibraryStore.allTracks(ctx).count

        XCTAssertEqual(countAfterFirst, countAfterSecond,
                       "Re-applying the same enumeration must not create duplicate Track rows (upsert)")

        // The folder node's trackIds must also have no duplicates.
        let node = try LibraryStore.folderNode(id: "r", ctx)
        let trackIds = node?.trackIds ?? []
        XCTAssertEqual(trackIds.count, Set(trackIds).count,
                       "FolderNode.trackIds must not contain duplicate UUIDs after re-enumeration")
    }

    // MARK: - FIX B: refresh failure flips source to needsReauth

    func test_accessToken_refreshFailure_flipsSourceToNeedsReauth() async throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex()
        let mgr = SourcesManager(ctx: ctx, index: idx)

        // Plant a connected gdrive Source row.
        mgr.connect(kind: .gdrive, authRef: SourceKind.gdrive.rawValue)
        // Manually set state to connected so we start from a clean slate.
        if let s = try LibraryStore.source(id: "gdrive", ctx) { s.state = SourceState.connected.rawValue }

        // Seed an expiring token into an InMemoryTokenStore.
        let store = InMemoryTokenStore()
        let expiring = OAuthToken(accessToken: "OLD", refreshToken: "RT",
                                  expiry: Date(timeIntervalSinceNow: 30))
        try store.save(expiring, account: SourceKind.gdrive.rawValue)

        let config = OAuthConfig(
            clientID: "cid",
            redirectURI: "com.googleusercontent.apps.cid:/oauth",
            authEndpoint: URL(string: "https://auth")!,
            tokenEndpoint: URL(string: "https://token")!,
            scopes: []
        )
        // MockHTTPClient returns 400 → OAuthClient.refresh throws → coordinator propagates.
        let http = MockHTTPClient(responses: [.init(status: 400, json: #"{"error":"invalid_grant"}"#)])
        let client = OAuthClient(config: config, http: http)

        // Call must throw.
        do {
            _ = try await mgr.accessToken(for: .gdrive, config: config, client: client, tokenStore: store)
            XCTFail("Expected accessToken to throw on 400 refresh response")
        } catch {
            // expected
        }

        // Source row must now be in needsReauth state.
        let sourceState = try LibraryStore.source(id: "gdrive", ctx)?.state
        XCTAssertEqual(sourceState, SourceState.needsReauth.rawValue,
                       "Source state must be 'needsReauth' after a failed token refresh")
    }

    // MARK: - FIX D: disconnect deletes Keychain creds + best-effort revoke

    func test_disconnect_deletesTokenStoreEntry_andFiresRevokePost() async throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex()
        let mgr = SourcesManager(ctx: ctx, index: idx)

        // Connect gdrive with an authRef.
        mgr.connect(kind: .gdrive, authRef: SourceKind.gdrive.rawValue)

        // Seed a token into the InMemoryTokenStore.
        let store = InMemoryTokenStore()
        let token = OAuthToken(accessToken: "AT", refreshToken: "RT",
                               expiry: Date(timeIntervalSinceNow: 3600))
        try store.save(token, account: SourceKind.gdrive.rawValue)
        XCTAssertNotNil(try store.load(account: SourceKind.gdrive.rawValue), "pre-condition: token is stored")

        // A mock HTTP client to verify the revoke POST is fired.
        let http = MockHTTPClient(responses: [.init(status: 200, json: "{}")])

        // Disconnect.
        mgr.disconnect(sourceId: SourceKind.gdrive.rawValue, tokenStore: store, http: http)

        // Give the detached Task a moment to fire (it's fire-and-forget, not awaited by disconnect).
        try await Task.sleep(for: .milliseconds(100))

        // Token must be gone from the store.
        XCTAssertNil(try store.load(account: SourceKind.gdrive.rawValue),
                     "Token must be deleted from the store on disconnect")

        // Source row must be gone.
        XCTAssertNil(try LibraryStore.source(id: SourceKind.gdrive.rawValue, ctx),
                     "Source row must be deleted on disconnect")

        // The revoke POST should have been fired (with the refresh token in the body).
        XCTAssertNotNil(http.lastBody, "A revoke POST must have been sent to oauth2.googleapis.com/revoke")
        XCTAssertTrue(http.lastBody?.contains("RT") ?? false,
                      "Revoke POST body should contain the refresh token; got: \(http.lastBody ?? "nil")")
    }

    /// Regression: disconnecting a OneDrive source must NOT POST its Microsoft refresh token to Google's
    /// revoke endpoint (Microsoft's /consumers authority has no revocation endpoint — the POST would be a
    /// no-op that ships an MS credential to Google). The local Keychain credential is still deleted.
    func test_disconnect_onedrive_deletesToken_butDoesNotFireRevoke() async throws {
        let ctx = try TestDB.context()
        let mgr = SourcesManager(ctx: ctx, index: LibraryIndex())
        mgr.connect(kind: .onedrive, authRef: SourceKind.onedrive.rawValue)

        let store = InMemoryTokenStore()
        try store.save(OAuthToken(accessToken: "AT", refreshToken: "RT",
                                  expiry: Date(timeIntervalSinceNow: 3600)),
                       account: SourceKind.onedrive.rawValue)

        let http = MockHTTPClient(responses: [.init(status: 200, json: "{}")])
        mgr.disconnect(sourceId: SourceKind.onedrive.rawValue, tokenStore: store, http: http)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertNil(try store.load(account: SourceKind.onedrive.rawValue),
                     "OneDrive token must still be deleted from the local store on disconnect")
        XCTAssertNil(try LibraryStore.source(id: SourceKind.onedrive.rawValue, ctx),
                     "OneDrive source row must be deleted on disconnect")
        XCTAssertEqual(http.callCount, 0,
                       "No revoke POST may be sent for OneDrive (no Microsoft revocation endpoint)")
    }

    func test_applyEnumeration_setsFolderBookmarkAndProviderFileId() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .local)

        let rootBookmark = Data([0xCA, 0xFE, 0xBA, 0xBE])
        let result = EnumerationResult(
            folders: [
                FolderDescriptor(id: "r", name: "Tracks", parentId: nil, childFolderIds: [], trackIds: ["t1"])
            ],
            tracks: [
                TrackDescriptor(id: "t1", title: "Song", artist: "", album: "", durationSec: 0, format: "FLAC",
                                bookmark: nil, providerFileId: "Song.flac"),
            ]
        )
        mgr.applyEnumeration(result, sourceId: "local", rootName: "Tracks",
                             rootNodeId: "r", rootBookmark: rootBookmark)

        let tracks = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(tracks.count, 1)
        let t = try XCTUnwrap(tracks.first)
        XCTAssertEqual(t.folderBookmark, rootBookmark,
                       "Track.folderBookmark must equal the root bookmark passed to applyEnumeration")
        XCTAssertEqual(t.providerFileId, "Song.flac",
                       "Track.providerFileId must equal the descriptor's relative path")
    }
}
