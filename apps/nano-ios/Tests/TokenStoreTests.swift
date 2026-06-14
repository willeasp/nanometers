import XCTest
@testable import NanoMeters

final class TokenStoreTests: XCTestCase {
    func test_inMemory_saveLoadDelete() throws {
        let s = InMemoryTokenStore()
        let tok = OAuthToken(accessToken: "a", refreshToken: "r", expiry: .init(timeIntervalSince1970: 1000))
        try s.save(tok, account: "gdrive")
        XCTAssertEqual(try s.load(account: "gdrive")?.accessToken, "a")
        try s.delete(account: "gdrive")
        XCTAssertNil(try s.load(account: "gdrive"))
    }
    func test_token_isExpired_withSkew() {
        let past = OAuthToken(accessToken: "a", refreshToken: "r", expiry: .init(timeIntervalSinceNow: 30))
        XCTAssertTrue(past.isExpiring(skew: 60))    // within 60s skew → treat as expiring
        let fresh = OAuthToken(accessToken: "a", refreshToken: "r", expiry: .init(timeIntervalSinceNow: 3600))
        XCTAssertFalse(fresh.isExpiring(skew: 60))
    }
}
