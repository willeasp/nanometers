import XCTest
@testable import NanoMeters

/// Regression: a rotated refresh token (the provider returning a NEW refresh_token on refresh) must be
/// persisted, not just returned. Microsoft Graph rotates the refresh token on every refresh, so if we
/// kept saving the OLD one the OneDrive source would die after the first rotation. (Google reuses the
/// refresh token, so this never bit us before.) The coordinator already saves the rotated token via
/// `store.save(refreshed, ...)`; this locks that in.
final class TokenRefreshRotationTests: XCTestCase {
    private let config = OAuthConfig(
        clientID: "cid", redirectURI: "s:/oauth",
        authEndpoint: URL(string: "https://auth")!,
        tokenEndpoint: URL(string: "https://token")!,
        scopes: [])

    func test_rotatedRefreshToken_isPersisted() async throws {
        let account = "onedrive-rotation-\(UUID().uuidString)"
        let store = InMemoryTokenStore()
        // Expired token holding the OLD refresh token.
        try store.save(OAuthToken(accessToken: "AT1", refreshToken: "OLD",
                                  expiry: Date(timeIntervalSinceNow: -60)), account: account)

        // Server rotates: returns a NEW refresh token alongside the fresh access token.
        let http = MockHTTPClient(responses: [
            .init(json: #"{"access_token":"AT2","refresh_token":"NEW","expires_in":3600}"#)])
        let client = OAuthClient(config: config, http: http)

        let tok = try await TokenRefreshCoordinator.shared.validToken(
            account: account, store: store, client: client, forceRefresh: true)

        XCTAssertEqual(tok.refreshToken, "NEW", "returned token must carry the rotated refresh token")
        XCTAssertEqual(try store.load(account: account)?.refreshToken, "NEW",
                       "rotated refresh token must be PERSISTED — otherwise the source dies after one rotation")
    }
}
