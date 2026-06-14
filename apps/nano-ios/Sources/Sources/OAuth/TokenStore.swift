import Foundation

struct OAuthToken: Codable, Equatable {
    var accessToken: String; var refreshToken: String?; var expiry: Date
    func isExpiring(skew: TimeInterval) -> Bool { Date(timeIntervalSinceNow: skew) >= expiry }
}

protocol TokenStore {
    func save(_ t: OAuthToken, account: String) throws
    func load(account: String) throws -> OAuthToken?
    func delete(account: String) throws
}

final class InMemoryTokenStore: TokenStore {
    private var d: [String: OAuthToken] = [:]
    func save(_ t: OAuthToken, account: String) throws { d[account] = t }
    func load(account: String) throws -> OAuthToken? { d[account] }
    func delete(account: String) throws { d[account] = nil }
}
