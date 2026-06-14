import Foundation

/// THE credential-injection seam. One value to set (GoogleOAuthClientID in project.yml); nothing else.
struct OAuthConfig {
    var clientID: String; var redirectScheme: String
    var authEndpoint: URL; var tokenEndpoint: URL; var scopes: [String]
    var redirectURI: String { "\(redirectScheme):/oauth" }
    static let placeholder = "YOUR_GOOGLE_IOS_CLIENT_ID"
    var isConfigured: Bool { !clientID.isEmpty && clientID != Self.placeholder }
    /// Reads the iOS OAuth client id from Info.plist key `GoogleOAuthClientID` (set in project.yml). The
    /// redirect scheme is the reversed client id (Google iOS convention). One value to set; nothing else.
    static var google: OAuthConfig {
        let id = (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String) ?? placeholder
        return OAuthConfig(clientID: id, redirectScheme: reversedScheme(for: id),
                           authEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                           tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                           scopes: ["https://www.googleapis.com/auth/drive.readonly"])
    }
    /// "<n>-<hash>.apps.googleusercontent.com" → "com.googleusercontent.apps.<n>-<hash>".
    static func reversedScheme(for clientID: String) -> String {
        let core = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(core)"
    }
}
