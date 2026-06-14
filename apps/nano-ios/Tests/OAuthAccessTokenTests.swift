import XCTest
import SwiftData
@testable import NanoMeters

/// Unit-tests SourcesManager.accessToken(for:config:client:tokenStore:).
/// Network is mocked; no Keychain; no SwiftData changes under test.
@MainActor
final class OAuthAccessTokenTests: XCTestCase {

    private let config = OAuthConfig(
        clientID: "cid",
        redirectScheme: "com.googleusercontent.apps.cid",
        authEndpoint: URL(string: "https://auth")!,
        tokenEndpoint: URL(string: "https://token")!,
        scopes: []
    )

    // Helpers to build a SourcesManager without SwiftData side-effects.
    private func makeManager() throws -> SourcesManager {
        let ctx = try TestDB.context()
        return SourcesManager(ctx: ctx, index: LibraryIndex())
    }

    // MARK: - Refresh path

    func test_accessToken_refreshesExpiringToken_andPersistsNewToken() async throws {
        let store = InMemoryTokenStore()
        // Store a token expiring in 30 s (within the 60 s skew → isExpiring == true).
        let expiring = OAuthToken(accessToken: "OLD", refreshToken: "RT",
                                  expiry: Date(timeIntervalSinceNow: 30))
        try store.save(expiring, account: SourceKind.gdrive.rawValue)

        let http = MockHTTPClient(responses: [
            .init(json: #"{"access_token":"NEW","refresh_token":"RT2","expires_in":3600}"#)
        ])
        let client = OAuthClient(config: config, http: http)
        let mgr = try makeManager()

        let at = try await mgr.accessToken(for: .gdrive, config: config, client: client, tokenStore: store)
        XCTAssertEqual(at, "NEW", "should return the refreshed access token")

        // Persisted token must be the new one.
        let stored = try store.load(account: SourceKind.gdrive.rawValue)
        XCTAssertEqual(stored?.accessToken, "NEW", "refreshed token must be persisted in the store")
        XCTAssertEqual(stored?.refreshToken, "RT2", "new refresh token must be persisted")
    }

    // MARK: - Non-expiring path (no network call)

    func test_accessToken_returnsFreshTokenWithoutNetworkCall() async throws {
        let store = InMemoryTokenStore()
        // Token expiring in 2 hours — well outside the 60 s skew → no refresh.
        let fresh = OAuthToken(accessToken: "FRESH", refreshToken: "RT",
                               expiry: Date(timeIntervalSinceNow: 7200))
        try store.save(fresh, account: SourceKind.gdrive.rawValue)

        let http = MockHTTPClient(responses: [])   // no stubs; a network call would return "{}" → error
        let client = OAuthClient(config: config, http: http)
        let mgr = try makeManager()

        let at = try await mgr.accessToken(for: .gdrive, config: config, client: client, tokenStore: store)
        XCTAssertEqual(at, "FRESH", "should return stored access token without a refresh call")
        XCTAssertNil(http.lastBody, "no HTTP request should have been made for a fresh token")
    }

    // MARK: - Missing token → throws

    func test_accessToken_throwsWhenNoTokenStored() async throws {
        let store = InMemoryTokenStore()   // empty
        let http = MockHTTPClient(responses: [])
        let client = OAuthClient(config: config, http: http)
        let mgr = try makeManager()

        do {
            _ = try await mgr.accessToken(for: .gdrive, config: config, client: client, tokenStore: store)
            XCTFail("Expected an error when no token is stored")
        } catch {
            // expected
        }
    }

    // MARK: - FIX A: Concurrent coalescing — exactly one refresh POST for N concurrent callers

    /// N concurrent `validToken` calls on the shared coordinator for the same expiring token must
    /// result in exactly ONE refresh POST, and ALL callers must receive the new access token.
    func test_coordinator_coalescesNConcurrentRefreshesIntoOnePost() async throws {
        let store = InMemoryTokenStore()
        let expiring = OAuthToken(accessToken: "OLD", refreshToken: "RT",
                                  expiry: Date(timeIntervalSinceNow: 30))
        try store.save(expiring, account: "gdrive")

        // CountingHTTPClient is actor-isolated so concurrent calls are safe.
        let http = CountingHTTPClient(responses: Array(
            repeating: CountingHTTPClient.Stub(
                json: #"{"access_token":"NEW","refresh_token":"RT2","expires_in":3600}"#),
            count: 10   // plenty of stubs; only one should be consumed
        ))
        // Bridge the actor into the HTTPClient protocol so OAuthClient can call it.
        let countingClient = OAuthClient(config: config, http: ActorBridgeHTTPClient(actor: http))

        // Reset the coordinator's in-flight slot in case a previous test left one (no-op if empty).
        // We use a fresh account key to isolate this test from other tests in the suite.
        let account = "gdrive-concurrent-test-\(UUID().uuidString)"
        let isolatedStore = InMemoryTokenStore()
        try isolatedStore.save(expiring, account: account)

        let coordinator = TokenRefreshCoordinator.shared
        let n = 8
        var results: [String] = Array(repeating: "", count: n)
        // Fire N concurrent validToken calls on the same account.
        await withTaskGroup(of: (Int, String?).self) { group in
            for i in 0..<n {
                group.addTask {
                    let tok = try? await coordinator.validToken(
                        account: account,
                        store: isolatedStore,
                        client: countingClient,
                        forceRefresh: false)
                    return (i, tok?.accessToken)
                }
            }
            for await (i, at) in group { results[i] = at ?? "nil" }
        }

        let postCount = await http.callCount
        XCTAssertEqual(postCount, 1, "exactly ONE refresh POST should have been issued for \(n) concurrent callers")
        XCTAssertTrue(results.allSatisfy { $0 == "NEW" },
                      "all concurrent callers must receive the new access token; got: \(results)")
    }

    // MARK: - FIX A: failure-then-recovery — failed Task clears the slot

    /// A refresh failure must clear the coordinator's in-flight slot so a subsequent call can retry.
    func test_coordinator_failedRefreshClearsSlot_subsequentCallSucceeds() async throws {
        let account = "gdrive-fail-recovery-\(UUID().uuidString)"
        let expiring = OAuthToken(accessToken: "OLD", refreshToken: "RT",
                                  expiry: Date(timeIntervalSinceNow: 30))
        let store = InMemoryTokenStore()
        try store.save(expiring, account: account)

        // First call: server returns 400 → refresh throws.
        let failHTTP = MockHTTPClient(responses: [
            .init(status: 400, json: #"{"error":"invalid_grant"}"#),
            .init(status: 200, json: #"{"access_token":"RECOVERED","refresh_token":"RT3","expires_in":3600}"#)
        ])
        let client = OAuthClient(config: config, http: failHTTP)
        let coordinator = TokenRefreshCoordinator.shared

        // First call must throw (400 from /token).
        do {
            _ = try await coordinator.validToken(account: account, store: store,
                                                  client: client, forceRefresh: false)
            XCTFail("Expected first validToken to throw on 400 from server")
        } catch {
            // expected — slot must now be cleared
        }

        // Second call: the stored token is still expiring (save didn't happen on failure),
        // but the slot is clear so a fresh refresh attempt is allowed.
        let recovered = try await coordinator.validToken(account: account, store: store,
                                                         client: client, forceRefresh: false)
        XCTAssertEqual(recovered.accessToken, "RECOVERED",
                       "second call after a failed refresh must attempt a new refresh and succeed")
    }
}
