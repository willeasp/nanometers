import XCTest
@testable import NanoMeters

/// Exercises the REAL Keychain (not InMemoryTokenStore). This is the regression guard for the
/// `keychain-access-groups` entitlement: without it, `SecItemAdd` fails with errSecMissingEntitlement
/// (-34018) and `save` throws — which is exactly the bug that blocked the live Google Drive sign-in.
final class KeychainTokenStoreTests: XCTestCase {
    func test_saveLoadDelete_roundTrips() throws {
        let store = KeychainTokenStore()
        let account = "test-\(UUID().uuidString)"
        defer { try? store.delete(account: account) }

        let token = OAuthToken(accessToken: "abc123",
                               refreshToken: "refresh-xyz",
                               expiry: Date(timeIntervalSince1970: 1_900_000_000))
        // Throws an NSError(domain: "Keychain", code: -34018) here if the entitlement is missing.
        try store.save(token, account: account)

        XCTAssertEqual(try store.load(account: account), token)

        try store.delete(account: account)
        XCTAssertNil(try store.load(account: account))
    }
}
