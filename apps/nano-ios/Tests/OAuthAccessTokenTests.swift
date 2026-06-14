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
}
