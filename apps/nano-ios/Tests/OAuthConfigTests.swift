import XCTest
@testable import NanoMeters

final class OAuthConfigTests: XCTestCase {
    func test_microsoft_endpointsScopesAndRedirect() {
        let cfg = OAuthConfig.microsoft
        XCTAssertEqual(cfg.authEndpoint.absoluteString,
                       "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")
        XCTAssertEqual(cfg.tokenEndpoint.absoluteString,
                       "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")
        XCTAssertEqual(cfg.scopes, ["Files.Read", "offline_access"])
        XCTAssertEqual(cfg.redirectScheme, "msauth.com.willeasp.nanometers.ios")
        XCTAssertEqual(cfg.redirectURI, "msauth.com.willeasp.nanometers.ios://auth")
        XCTAssertEqual(cfg.extraAuthParams, ["prompt": "select_account"])
    }
    func test_google_paramsAndRedirectUnchanged() {
        let cfg = OAuthConfig.google
        XCTAssertEqual(cfg.extraAuthParams, ["access_type": "offline", "prompt": "consent"])
        XCTAssertTrue(cfg.redirectURI.hasSuffix(":/oauth"),
                      "Google redirect must keep the reversed-id :/oauth form; got \(cfg.redirectURI)")
    }
}
