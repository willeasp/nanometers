import XCTest
@testable import NanoMeters

final class OAuthClientTests: XCTestCase {
    func test_exchange_postsCodeVerifierAndParsesTokens() async throws {
        let http = MockHTTPClient(responses: [
            .init(json: #"{"access_token":"AT","refresh_token":"RT","expires_in":3600}"#)])
        let cfg = OAuthConfig(clientID: "cid", redirectScheme: "com.googleusercontent.apps.cid",
                              authEndpoint: URL(string: "https://auth")!, tokenEndpoint: URL(string: "https://token")!,
                              scopes: ["drive.readonly"])
        let client = OAuthClient(config: cfg, http: http)
        let tok = try await client.exchange(code: "CODE", verifier: "VER", redirectURI: "com.googleusercontent.apps.cid:/oauth")
        XCTAssertEqual(tok.accessToken, "AT"); XCTAssertEqual(tok.refreshToken, "RT")
        XCTAssertGreaterThan(tok.expiry, Date())
        // Verify the POST body carried grant_type=authorization_code, code, code_verifier, client_id, redirect_uri.
        let body = http.lastBody ?? ""
        XCTAssertTrue(body.contains("grant_type=authorization_code"))
        XCTAssertTrue(body.contains("code_verifier=VER")); XCTAssertTrue(body.contains("code=CODE"))
    }
    func test_refresh_usesRefreshToken_keepsOldRefreshIfOmitted() async throws {
        let http = MockHTTPClient(responses: [.init(json: #"{"access_token":"AT2","expires_in":3600}"#)])
        let cfg = OAuthConfig(clientID: "cid", redirectScheme: "s", authEndpoint: URL(string: "https://a")!,
                              tokenEndpoint: URL(string: "https://token")!, scopes: [])
        let client = OAuthClient(config: cfg, http: http)
        let tok = try await client.refresh(refreshToken: "RT")
        XCTAssertEqual(tok.accessToken, "AT2"); XCTAssertEqual(tok.refreshToken, "RT")  // reused
        XCTAssertTrue((http.lastBody ?? "").contains("grant_type=refresh_token"))
    }
    func test_authorizeURL_carriesPKCEAndState() {
        let cfg = OAuthConfig(clientID: "cid", redirectScheme: "s", authEndpoint: URL(string: "https://auth")!,
                              tokenEndpoint: URL(string: "https://t")!, scopes: ["drive.readonly"])
        let url = OAuthClient(config: cfg, http: MockHTTPClient(responses: []))
            .authorizeURL(challenge: "CH", state: "ST", redirectURI: "s:/oauth")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "code_challenge" }?.value, "CH")
        XCTAssertEqual(q.first { $0.name == "code_challenge_method" }?.value, "S256")
        XCTAssertEqual(q.first { $0.name == "state" }?.value, "ST")
        XCTAssertEqual(q.first { $0.name == "client_id" }?.value, "cid")
    }
    func test_authorizeURL_requestsOfflineAccessAndConsent() {
        // Without access_type=offline Google never issues a refresh token (the source dies ~1h after
        // connect); without prompt=consent a re-auth can't re-issue one. These now ride through
        // extraAuthParams rather than being hardcoded in authorizeURL.
        let cfg = OAuthConfig(clientID: "cid", redirectScheme: "s", authEndpoint: URL(string: "https://auth")!,
                              tokenEndpoint: URL(string: "https://t")!, scopes: ["drive.readonly"],
                              extraAuthParams: ["access_type": "offline", "prompt": "consent"])
        let url = OAuthClient(config: cfg, http: MockHTTPClient(responses: []))
            .authorizeURL(challenge: "CH", state: "ST", redirectURI: "s:/oauth")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "access_type" }?.value, "offline")
        XCTAssertEqual(q.first { $0.name == "prompt" }?.value, "consent")
    }
    func test_authorizeURL_microsoft_noAccessType_hasSelectAccount() {
        // Microsoft uses prompt=select_account and must NOT carry Google's access_type param.
        let cfg = OAuthConfig(clientID: "cid", redirectScheme: "s", authEndpoint: URL(string: "https://auth")!,
                              tokenEndpoint: URL(string: "https://t")!, scopes: ["Files.Read"],
                              extraAuthParams: ["prompt": "select_account"])
        let url = OAuthClient(config: cfg, http: MockHTTPClient(responses: []))
            .authorizeURL(challenge: "CH", state: "ST", redirectURI: "s://auth")
        let q = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        XCTAssertEqual(q.first { $0.name == "prompt" }?.value, "select_account")
        XCTAssertNil(q.first { $0.name == "access_type" }, "Microsoft must not emit access_type")
    }
}
