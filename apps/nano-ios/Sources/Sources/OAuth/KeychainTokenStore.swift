import Foundation
import Security

// kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlock (handoff §8.3).
final class KeychainTokenStore: TokenStore {
    private let service = "com.willeasp.nanometers.ios.oauth"
    func save(_ t: OAuthToken, account: String) throws {
        let data = try JSONEncoder().encode(t)
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                    kSecAttrService as String: service, kSecAttrAccount as String: account]
        SecItemDelete(base as CFDictionary)
        var add = base
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: "Keychain", code: Int(status)) }
    }
    func load(account: String) throws -> OAuthToken? {
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service, kSecAttrAccount as String: account,
                                kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]
        var out: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &out)
        guard status == errSecSuccess, let data = out as? Data else { return nil }
        return try JSONDecoder().decode(OAuthToken.self, from: data)
    }
    func delete(account: String) throws {
        SecItemDelete([kSecClass as String: kSecClassGenericPassword,
                       kSecAttrService as String: service, kSecAttrAccount as String: account] as CFDictionary)
    }
}
