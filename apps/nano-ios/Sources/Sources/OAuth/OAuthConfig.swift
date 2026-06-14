import Foundation

/// THE credential-injection seam. Two synced placeholders in project.yml: GoogleOAuthClientID (the iOS
/// client id) + the reversed-id CFBundleURLTypes scheme. Change both, then run `xcodegen generate`
/// (see docs/google-drive-setup.md).
struct OAuthConfig {
    var clientID: String; var redirectScheme: String
    var authEndpoint: URL; var tokenEndpoint: URL; var scopes: [String]
    var redirectURI: String { "\(redirectScheme):/oauth" }
    static let placeholder = "YOUR_GOOGLE_IOS_CLIENT_ID"
    var isConfigured: Bool { !clientID.isEmpty && clientID != Self.placeholder }
    /// Reads the iOS OAuth client id from Info.plist key `GoogleOAuthClientID` (set in project.yml). The
    /// redirect scheme is the reversed client id (Google iOS convention); both are set together in project.yml.
    static var google: OAuthConfig {
        var id = (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String) ?? placeholder
        #if DEBUG
        // Let UI tests assert the unconfigured ("Needs setup") state deterministically, regardless of
        // whether a local Secrets.xcconfig supplied a real client id to this build.
        if ProcessInfo.processInfo.arguments.contains("-force-drive-unconfigured") { id = placeholder }
        #endif
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
