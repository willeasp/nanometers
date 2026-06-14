import Foundation

/// THE credential-injection seam. Two synced placeholders in project.yml: GoogleOAuthClientID (the iOS
/// client id) + the reversed-id CFBundleURLTypes scheme. Change both, then run `xcodegen generate`
/// (see docs/google-drive-setup.md). Microsoft injects MicrosoftOAuthClientID + MicrosoftOAuthRedirectScheme.
struct OAuthConfig {
    var clientID: String; var redirectScheme: String
    var authEndpoint: URL; var tokenEndpoint: URL; var scopes: [String]
    /// Provider-specific authorize params (Google: access_type/prompt; Microsoft: prompt=select_account).
    var extraAuthParams: [String: String] = [:]
    /// Microsoft needs a custom redirect (`scheme://auth`); Google keeps the reversed-id `:/oauth` form.
    var redirectURIOverride: String? = nil
    var redirectURI: String { redirectURIOverride ?? "\(redirectScheme):/oauth" }
    static let placeholder = "YOUR_GOOGLE_IOS_CLIENT_ID"
    static let microsoftPlaceholder = "YOUR_MICROSOFT_CLIENT_ID"
    var isConfigured: Bool { !clientID.isEmpty && clientID != Self.placeholder && clientID != Self.microsoftPlaceholder }
    /// Reads the iOS OAuth client id from Info.plist key `GoogleOAuthClientID` (set in project.yml). The
    /// redirect scheme is the reversed client id (Google iOS convention); both are set together in project.yml.
    static var google: OAuthConfig {
        var id = (Bundle.main.object(forInfoDictionaryKey: "GoogleOAuthClientID") as? String) ?? placeholder
        #if DEBUG
        // Let UI tests assert the unconfigured ("Needs setup") state deterministically, regardless of
        // whether a local Secrets.xcconfig supplied a real client id to this build.
        let a = ProcessInfo.processInfo.arguments
        if a.contains("-force-drive-unconfigured") || a.contains("-force-cloud-unconfigured") { id = placeholder }
        #endif
        // access_type=offline → Google issues a refresh_token; prompt=consent forces the consent screen
        // so re-auth (Reconnect) re-issues one (Google only returns a refresh token on first consent
        // otherwise). Without these the source dies ~1h after connecting.
        return OAuthConfig(clientID: id, redirectScheme: reversedScheme(for: id),
                           authEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
                           tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
                           scopes: ["https://www.googleapis.com/auth/drive.readonly"],
                           extraAuthParams: ["access_type": "offline", "prompt": "consent"])
    }
    /// Reads the Microsoft app (client) id from Info.plist key `MicrosoftOAuthClientID`. The redirect
    /// scheme (`msauth.<bundle-id>`) registers the `scheme://auth` URI Azure expects for a public client.
    static var microsoft: OAuthConfig {
        var id = (Bundle.main.object(forInfoDictionaryKey: "MicrosoftOAuthClientID") as? String) ?? microsoftPlaceholder
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-force-cloud-unconfigured") { id = microsoftPlaceholder }
        #endif
        let scheme = (Bundle.main.object(forInfoDictionaryKey: "MicrosoftOAuthRedirectScheme") as? String) ?? "msauth.com.willeasp.nanometers.ios"
        // prompt=select_account lets the user pick / switch the Microsoft account on (re)connect.
        // offline_access scope → Graph issues a refresh_token.
        return OAuthConfig(clientID: id, redirectScheme: scheme,
                           authEndpoint: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")!,
                           tokenEndpoint: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!,
                           scopes: ["Files.Read", "offline_access"],
                           extraAuthParams: ["prompt": "select_account"],
                           redirectURIOverride: "\(scheme)://auth")
    }
    /// "<n>-<hash>.apps.googleusercontent.com" → "com.googleusercontent.apps.<n>-<hash>".
    static func reversedScheme(for clientID: String) -> String {
        let core = clientID.replacingOccurrences(of: ".apps.googleusercontent.com", with: "")
        return "com.googleusercontent.apps.\(core)"
    }
}
