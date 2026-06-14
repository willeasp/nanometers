# Library & Sources — Phase 5: OAuth + Google Drive + Streaming

> **For agentic workers:** REQUIRED SUB-SKILL: subagent-driven-development / executing-plans. Steps use `- [ ]`.

**Goal:** Google Drive as a working OAuth source. Authorization-Code + PKCE via `ASWebAuthenticationSession`, tokens in the Keychain, Drive REST v3 folder enumeration → the `FolderNode`/`Track` cache, and playback by downloading the file to an on-disk LRU cache (the cached file is a normal local URL, so the existing `AudioEngine`/`WaveformAnalyzer` play it unchanged). Everything is built behind a **single credential-injection seam** (the iOS client ID) and a **`MockSourceProvider`** so the whole flow is unit/UI-tested without network; the only manual step is the live Google consent screen.

**Architecture:** Testable cores are pure and mockable — `PKCE` (verifier/challenge), `TokenStore` protocol (`KeychainTokenStore` + `InMemoryTokenStore`), `OAuthClient` token exchange/refresh over an injected `URLSession`-like `HTTPClient`, `DriveAPIClient` (request building + JSON→descriptor parsing tested against fixtures), `GoogleDriveProvider` (enumeration over a mockable API client), `RemoteFileCache` (LRU). The interactive `ASWebAuthenticationSession` and real network are thin shells, exercised manually. `OAuthConfig.google` reads the client ID from `Info.plist` (set in `project.yml`); when absent it's `placeholder` and Drive Connect shows a "needs setup" state — the app builds and all non-Drive flows work regardless.

**Tech Stack:** Swift, `AuthenticationServices` (`ASWebAuthenticationSession`), `Security` (Keychain), `URLSession`, SwiftData. Sim **iPhone 16 Pro (Nano)** `28DD8D81-668A-4887-98E8-BFE3CC625596` (never 17).

**Spec:** `…design.md` §9 (OAuth + Drive), §10 (Google Cloud setup); handoff §08 (OAuth & integration spec), §07 (onboarding Branch B).

**Depends on Phase 4:** `SourceProvider` (`enumerate(rootBookmark:providerFolderId:rootName:rootId:) -> EnumerationResult`), `FolderDescriptor`/`TrackDescriptor`/`EnumerationResult`, `SourcesManager` (`connect`, `applyEnumeration`, `disconnect`), the Settings Sources manager UI, `SourceKind.gdrive`/`SourceState`.

---

## Conventions (every task)
- Unit `-only-testing:NanoMetersTests`; UI `-only-testing:NanoMetersUITests`. Nano sim (never 17).
- New file → `xcodegen generate`; **never `git add` the gitignored `NanoMeters.xcodeproj`**.
- Commit per task; end messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- **No real secrets in the repo.** PKCE means no client secret. The client ID is set via `project.yml` (Info.plist) by the user, not hard-coded.

---

## File Structure
**Create (under `Sources/Sources/OAuth/` and `Sources/Sources/Drive/`):**
- `OAuth/PKCE.swift`, `OAuth/OAuthConfig.swift`, `OAuth/TokenStore.swift`, `OAuth/KeychainTokenStore.swift`, `OAuth/OAuthClient.swift`, `OAuth/HTTPClient.swift`, `OAuth/WebAuthSession.swift`.
- `Drive/DriveAPIClient.swift`, `Drive/GoogleDriveProvider.swift`.
- `Sources/RemoteFileCache.swift`.
- `Sources/MockSourceProvider.swift` (used by tests + a debug connect hook).
- Tests: `Tests/PKCETests.swift`, `Tests/TokenStoreTests.swift`, `Tests/OAuthClientTests.swift`, `Tests/DriveAPIClientTests.swift`, `Tests/GoogleDriveProviderTests.swift`, `Tests/RemoteFileCacheTests.swift`.
- `UITests/DriveMockFlowUITests.swift`.
**Modify:**
- `apps/nano-ios/project.yml` — add `CFBundleURLTypes` (reversed-client-id scheme placeholder) + `GoogleOAuthClientID` info key.
- `Sources/Sources/SourcesManager.swift` — `connectOAuth(kind:)` (runs OAuthClient, stores token, sets state) + a provider registry.
- `Sources/Screens/SourcesSettingsView.swift` — Google Drive "Connect" runs OAuth; "Add Root" browses Drive folders.
- `Sources/Playback/AudioEngine.swift` — async `prepare(track)` downloads remote files to the cache before play.

---

## Task 1: PKCE (pure)

**Files:** Create `Sources/Sources/OAuth/PKCE.swift`, `Tests/PKCETests.swift`.

- [ ] **Step 1: Failing tests:**
```swift
import XCTest
import CryptoKit
@testable import NanoMeters

final class PKCETests: XCTestCase {
    func test_challenge_isBase64URLSha256OfVerifier_noPadding() {
        let p = PKCE(verifier: "abc123-_~.verifiertestvaluelongenough0000000000")
        let expected = Data(SHA256.hash(data: Data(p.verifier.utf8)))
            .base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        XCTAssertEqual(p.challenge, expected)
        XCTAssertEqual(p.method, "S256")
    }
    func test_generated_verifierLengthInRange_andURLSafe() {
        let p = PKCE.generate()
        XCTAssertTrue((43...128).contains(p.verifier.count))
        XCTAssertTrue(p.verifier.allSatisfy { "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~".contains($0) })
        XCTAssertFalse(p.challenge.contains("="))
    }
    func test_state_isRandom() { XCTAssertNotEqual(PKCE.randomState(), PKCE.randomState()) }
}
```
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `PKCE.swift`:
```swift
import Foundation
import CryptoKit

/// RFC 7636 PKCE (S256) + a random `state`. Pure + deterministic given a verifier, so it's unit-testable.
struct PKCE {
    let verifier: String
    var method: String { "S256" }
    var challenge: String {
        Self.base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }
    static func generate() -> PKCE {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return PKCE(verifier: base64URL(Data(bytes)))   // 64 bytes → 86 url-safe chars
    }
    static func randomState() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return base64URL(Data(bytes))
    }
    static func base64URL(_ d: Data) -> String {
        d.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
```
- [ ] **Step 4: Run — pass.** Commit: `feat(ios): PKCE (S256) + random state`.

---

## Task 2: TokenStore protocol + in-memory + Keychain

**Files:** Create `OAuth/TokenStore.swift`, `OAuth/KeychainTokenStore.swift`, `Tests/TokenStoreTests.swift`.

- [ ] **Step 1: Failing tests** (against the in-memory impl — Keychain isn't reliable in unit tests):
```swift
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
```
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement:**
```swift
// TokenStore.swift
import Foundation
struct OAuthToken: Codable, Equatable {
    var accessToken: String; var refreshToken: String?; var expiry: Date
    func isExpiring(skew: TimeInterval) -> Bool { Date(timeIntervalSinceNow: skew) >= expiry }
}
protocol TokenStore { func save(_ t: OAuthToken, account: String) throws
                      func load(account: String) throws -> OAuthToken?
                      func delete(account: String) throws }
final class InMemoryTokenStore: TokenStore {
    private var d: [String: OAuthToken] = [:]
    func save(_ t: OAuthToken, account: String) throws { d[account] = t }
    func load(account: String) throws -> OAuthToken? { d[account] }
    func delete(account: String) throws { d[account] = nil }
}
```
```swift
// KeychainTokenStore.swift — kSecClassGenericPassword, kSecAttrAccessibleAfterFirstUnlock (handoff §8.3).
import Foundation
import Security
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
```
- [ ] **Step 4: Run — pass.** Commit: `feat(ios): TokenStore (Keychain + in-memory) + OAuthToken`.

---

## Task 3: OAuthConfig (credential seam) + OAuthClient (token exchange/refresh)

**Files:** Create `OAuth/OAuthConfig.swift`, `OAuth/HTTPClient.swift`, `OAuth/OAuthClient.swift`, `Tests/OAuthClientTests.swift`.

- [ ] **Step 1: Failing tests** (exchange + refresh request building + response parsing over a mock HTTPClient):
```swift
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
}
```
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `HTTPClient.swift` (protocol + URLSession impl + `MockHTTPClient` for tests), `OAuthConfig.swift` (the credential seam), `OAuthClient.swift`:
```swift
// HTTPClient.swift
import Foundation
struct HTTPResponse { var status: Int; var data: Data }
protocol HTTPClient { func send(_ req: URLRequest) async throws -> HTTPResponse }
struct URLSessionHTTPClient: HTTPClient {
    func send(_ req: URLRequest) async throws -> HTTPResponse {
        let (data, resp) = try await URLSession.shared.data(for: req)
        return HTTPResponse(status: (resp as? HTTPURLResponse)?.statusCode ?? 0, data: data)
    }
}
final class MockHTTPClient: HTTPClient {           // test double
    struct Stub { var status = 200; var json: String }
    private var responses: [Stub]; private(set) var lastBody: String?
    init(responses: [Stub]) { self.responses = responses }
    func send(_ req: URLRequest) async throws -> HTTPResponse {
        lastBody = req.httpBody.flatMap { String(data: $0, encoding: .utf8) }
        let s = responses.isEmpty ? Stub(json: "{}") : responses.removeFirst()
        return HTTPResponse(status: s.status, data: Data(s.json.utf8))
    }
}
```
```swift
// OAuthConfig.swift — THE credential-injection seam.
import Foundation
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
```
```swift
// OAuthClient.swift — authorize URL + token exchange/refresh (interactive session is separate, Task 8).
import Foundation
struct OAuthClient {
    let config: OAuthConfig; let http: HTTPClient
    func authorizeURL(challenge: String, state: String, redirectURI: String) -> URL {
        var c = URLComponents(url: config.authEndpoint, resolvingAgainstBaseURL: false)!
        c.queryItems = [.init(name: "client_id", value: config.clientID), .init(name: "redirect_uri", value: redirectURI),
                        .init(name: "response_type", value: "code"), .init(name: "scope", value: config.scopes.joined(separator: " ")),
                        .init(name: "code_challenge", value: challenge), .init(name: "code_challenge_method", value: "S256"),
                        .init(name: "state", value: state)]
        return c.url!
    }
    func exchange(code: String, verifier: String, redirectURI: String) async throws -> OAuthToken {
        try await token(form: ["grant_type": "authorization_code", "code": code, "code_verifier": verifier,
                               "redirect_uri": redirectURI, "client_id": config.clientID], existingRefresh: nil)
    }
    func refresh(refreshToken: String) async throws -> OAuthToken {
        try await token(form: ["grant_type": "refresh_token", "refresh_token": refreshToken, "client_id": config.clientID],
                        existingRefresh: refreshToken)
    }
    private func token(form: [String: String], existingRefresh: String?) async throws -> OAuthToken {
        var req = URLRequest(url: config.tokenEndpoint); req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data(form.map { "\($0)=\($1.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $1)" }.joined(separator: "&").utf8)
        let resp = try await http.send(req)
        guard resp.status == 200 else { throw NSError(domain: "OAuth", code: resp.status) }
        struct R: Decodable { var access_token: String; var refresh_token: String?; var expires_in: Double? }
        let r = try JSONDecoder().decode(R.self, from: resp.data)
        return OAuthToken(accessToken: r.access_token, refreshToken: r.refresh_token ?? existingRefresh,
                          expiry: Date(timeIntervalSinceNow: r.expires_in ?? 3600))
    }
}
```
> The test's `code_verifier=VER` substring check requires the form encoding to keep `VER` literal — `.alphanumerics` percent-encoding leaves `VER`/`CODE`/`RT` unchanged, so the assertions hold. (If a value had reserved chars it'd encode; the test values are alphanumeric.)
- [ ] **Step 4: Run — pass.** Commit: `feat(ios): OAuthConfig credential seam + OAuthClient token exchange/refresh`.

---

## Task 4: DriveAPIClient — files.list parsing + request building

**Files:** Create `Drive/DriveAPIClient.swift`, `Tests/DriveAPIClientTests.swift`.

- [ ] **Step 1: Failing tests** (parse a `files.list` page into folders+tracks; build the list query + media URL):
```swift
import XCTest
@testable import NanoMeters

final class DriveAPIClientTests: XCTestCase {
    func test_parseList_splitsFoldersAndAudio_withNextPageToken() throws {
        let json = #"""
        {"nextPageToken":"NPT","files":[
          {"id":"f1","name":"House","mimeType":"application/vnd.google-apps.folder"},
          {"id":"a1","name":"Caldera.mp3","mimeType":"audio/mpeg"},
          {"id":"x1","name":"notes.txt","mimeType":"text/plain"}]}
        """#
        let page = try DriveAPIClient.parseList(Data(json.utf8))
        XCTAssertEqual(page.nextPageToken, "NPT")
        XCTAssertEqual(page.folders.map(\.id), ["f1"])
        XCTAssertEqual(page.tracks.map(\.id), ["a1"])      // audio/* only; text filtered
        XCTAssertEqual(page.tracks.first?.name, "Caldera.mp3")
    }
    func test_listRequest_carriesParentQueryAndAuth() {
        let req = DriveAPIClient.listRequest(parentId: "root", pageToken: "PT", accessToken: "AT")
        let url = req.url!.absoluteString
        XCTAssertTrue(url.contains("'root'%20in%20parents") || url.contains("'root' in parents"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertTrue(url.contains("pageToken=PT"))
    }
    func test_mediaRequest_isAltMedia_withRange_andAuth() {
        let req = DriveAPIClient.mediaRequest(fileId: "a1", accessToken: "AT", offset: 0)
        XCTAssertTrue(req.url!.absoluteString.contains("/files/a1?alt=media"))
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer AT")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Range"), "bytes=0-")
    }
}
```
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `DriveAPIClient.swift` (static helpers + an instance that pages over `HTTPClient`):
```swift
import Foundation
enum DriveAudioMime { static func isAudio(_ m: String) -> Bool { m.hasPrefix("audio/") } }
struct DriveFile: Decodable, Equatable { var id: String; var name: String; var mimeType: String }
struct DriveListPage: Equatable { var folders: [DriveFile]; var tracks: [DriveFile]; var nextPageToken: String? }

struct DriveAPIClient {
    let http: HTTPClient
    static let folderMime = "application/vnd.google-apps.folder"
    static func parseList(_ data: Data) throws -> DriveListPage {
        struct R: Decodable { var nextPageToken: String?; var files: [DriveFile]? }
        let r = try JSONDecoder().decode(R.self, from: data)
        let files = r.files ?? []
        return DriveListPage(folders: files.filter { $0.mimeType == folderMime },
                             tracks: files.filter { DriveAudioMime.isAudio($0.mimeType) },
                             nextPageToken: r.nextPageToken)
    }
    static func listRequest(parentId: String, pageToken: String?, accessToken: String) -> URLRequest {
        var c = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
        c.queryItems = [.init(name: "q", value: "'\(parentId)' in parents and trashed=false"),
                        .init(name: "fields", value: "nextPageToken,files(id,name,mimeType)"),
                        .init(name: "pageSize", value: "1000")]
        if let pageToken { c.queryItems?.append(.init(name: "pageToken", value: pageToken)) }
        var req = URLRequest(url: c.url!); req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        return req
    }
    static func mediaRequest(fileId: String, accessToken: String, offset: Int) -> URLRequest {
        var req = URLRequest(url: URL(string: "https://www.googleapis.com/drive/v3/files/\(fileId)?alt=media")!)
        req.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("bytes=\(offset)-", forHTTPHeaderField: "Range")
        return req
    }
    /// List all children of a folder, following nextPageToken.
    func listChildren(parentId: String, accessToken: String) async throws -> (folders: [DriveFile], tracks: [DriveFile]) {
        var folders: [DriveFile] = [], tracks: [DriveFile] = [], token: String? = nil
        repeat {
            let resp = try await http.send(Self.listRequest(parentId: parentId, pageToken: token, accessToken: accessToken))
            guard resp.status == 200 else { throw NSError(domain: "Drive", code: resp.status) }
            let page = try Self.parseList(resp.data)
            folders += page.folders; tracks += page.tracks; token = page.nextPageToken
        } while token != nil
        return (folders, tracks)
    }
}
```
- [ ] **Step 4: Run — pass.** Commit: `feat(ios): DriveAPIClient — files.list parsing + media/list request building`.

---

## Task 5: GoogleDriveProvider — enumerate a Drive subtree → descriptors

**Files:** Create `Drive/GoogleDriveProvider.swift`, `Tests/GoogleDriveProviderTests.swift`.

Recursively enumerate from a root folder id into `EnumerationResult` (the Phase-4 type), using a token supplier + the API client (mocked in tests). Tracks carry `providerFileId`; folders carry the Drive folder id.

- [ ] **Step 1: Failing test** (mock API returns a 2-level tree):
```swift
import XCTest
@testable import NanoMeters

final class GoogleDriveProviderTests: XCTestCase {
    func test_enumerate_buildsFolderTreeAndTrackDescriptors() async throws {
        // root "mine" → folder "house" + track "intro"; house → track "deep".
        let http = MockHTTPClient(responses: [
            .init(json: #"{"files":[{"id":"house","name":"House","mimeType":"application/vnd.google-apps.folder"},{"id":"intro","name":"Intro.mp3","mimeType":"audio/mpeg"}]}"#),
            .init(json: #"{"files":[{"id":"deep","name":"Deep.wav","mimeType":"audio/wav"}]}"#)])
        let provider = GoogleDriveProvider(api: DriveAPIClient(http: http), accessToken: { "AT" })
        let r = try await provider.enumerate(rootBookmark: nil, providerFolderId: "mine", rootName: "My Productions", rootId: "mine")
        XCTAssertEqual(Set(r.folders.map(\.name)), ["My Productions", "House"])
        let root = r.folders.first { $0.id == "mine" }!
        XCTAssertTrue(root.childFolderIds.contains("house"))
        XCTAssertEqual(root.trackIds, ["intro"])
        XCTAssertEqual(r.folders.first { $0.id == "house" }?.trackIds, ["deep"])
        XCTAssertEqual(Set(r.tracks.map(\.providerFileId)), ["intro", "deep"])
        XCTAssertTrue(r.tracks.allSatisfy { $0.bookmark == nil })   // cloud → no bookmark
    }
}
```
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `GoogleDriveProvider.swift`:
```swift
import Foundation
/// Enumerates a Drive subtree into provider-agnostic descriptors (handoff §08.5). `accessToken` is supplied
/// by the caller (SourcesManager refreshes via OAuthClient), so this stays testable with a static token.
struct GoogleDriveProvider: SourceProvider {
    var kind: SourceKind { .gdrive }
    let api: DriveAPIClient
    let accessToken: () async throws -> String

    func enumerate(rootBookmark: Data?, providerFolderId: String?, rootName: String, rootId: String) async throws -> EnumerationResult {
        var folders: [FolderDescriptor] = []; var tracks: [TrackDescriptor] = []
        try await walk(folderId: rootId, name: rootName, parentId: nil, folders: &folders, tracks: &tracks)
        return EnumerationResult(folders: folders, tracks: tracks)
    }
    private func walk(folderId: String, name: String, parentId: String?,
                      folders: inout [FolderDescriptor], tracks: inout [TrackDescriptor]) async throws {
        let token = try await accessToken()
        let (subFolders, subTracks) = try await api.listChildren(parentId: folderId, accessToken: token)
        var childIds: [String] = []; var trackIds: [String] = []
        for f in subFolders { childIds.append(f.id) }
        for t in subTracks {
            trackIds.append(t.id)
            tracks.append(TrackDescriptor(id: t.id, title: (t.name as NSString).deletingPathExtension, artist: "",
                                          album: "", durationSec: 0, format: (t.name as NSString).pathExtension.uppercased(),
                                          bookmark: nil, providerFileId: t.id))
        }
        folders.append(FolderDescriptor(id: folderId, name: name, parentId: parentId, childFolderIds: childIds, trackIds: trackIds))
        for f in subFolders { try await walk(folderId: f.id, name: f.name, parentId: folderId, folders: &folders, tracks: &tracks) }
    }
}
```
- [ ] **Step 4: Run — pass.** Commit: `feat(ios): GoogleDriveProvider — recursive Drive enumeration → descriptors`.

---

## Task 6: RemoteFileCache (LRU on-disk)

**Files:** Create `Sources/Sources/RemoteFileCache.swift`, `Tests/RemoteFileCacheTests.swift`.

- [ ] **Step 1: Failing tests** (cache write, hit, LRU eviction over a byte budget — uses a temp dir; downloader injected):
```swift
import XCTest
@testable import NanoMeters

final class RemoteFileCacheTests: XCTestCase {
    func test_storeAndHit_returnsLocalURL() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfc-\(UUID())")
        let cache = RemoteFileCache(directory: dir, maxBytes: 10_000)
        let url = try await cache.localURL(sourceId: "gdrive", fileId: "a1") { Data(repeating: 1, count: 100) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        var called = false
        _ = try await cache.localURL(sourceId: "gdrive", fileId: "a1") { called = true; return Data() }
        XCTAssertFalse(called)   // second call is a cache hit, downloader not invoked
        try? FileManager.default.removeItem(at: dir)
    }
    func test_lru_evictsOldestOverBudget() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rfc-\(UUID())")
        let cache = RemoteFileCache(directory: dir, maxBytes: 250)
        _ = try await cache.localURL(sourceId: "s", fileId: "a") { Data(repeating: 1, count: 100) }
        _ = try await cache.localURL(sourceId: "s", fileId: "b") { Data(repeating: 1, count: 100) }
        _ = try await cache.localURL(sourceId: "s", fileId: "c") { Data(repeating: 1, count: 100) }  // 300 > 250 → evict "a"
        XCTAssertFalse(cache.isCached(sourceId: "s", fileId: "a"))
        XCTAssertTrue(cache.isCached(sourceId: "s", fileId: "c"))
        try? FileManager.default.removeItem(at: dir)
    }
}
```
- [ ] **Step 2: Run — fails.**
- [ ] **Step 3: Implement** `RemoteFileCache.swift`:
```swift
import Foundation
/// LRU on-disk cache of downloaded provider files (handoff §08.5). Keyed by (sourceId, fileId); the cached
/// file is a normal local URL so AudioEngine/WaveformAnalyzer use it unchanged. `downloader` is injected so
/// the cache is testable without network.
actor RemoteFileCache {
    private let dir: URL; private let maxBytes: Int
    init(directory: URL, maxBytes: Int = 512 * 1024 * 1024) {
        self.dir = directory; self.maxBytes = maxBytes
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    private func key(_ s: String, _ f: String) -> String { "\(s)__\(f)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "\(s)_\(f)" }
    private func fileURL(_ s: String, _ f: String) -> URL { dir.appendingPathComponent(key(s, f)) }
    nonisolated func isCached(sourceId: String, fileId: String) -> Bool {
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(("\(sourceId)__\(fileId)".addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")).path)
    }
    func localURL(sourceId: String, fileId: String, downloader: () async throws -> Data) async throws -> URL {
        let url = fileURL(sourceId, fileId)
        if FileManager.default.fileExists(atPath: url.path) { touch(url); return url }
        let data = try await downloader()
        try data.write(to: url)
        touch(url)
        evictIfNeeded()
        return url
    }
    private func touch(_ url: URL) { try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path) }
    private func evictIfNeeded() {
        let fm = FileManager.default
        var files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey])) ?? []
        func size(_ u: URL) -> Int { (try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        func mtime(_ u: URL) -> Date { (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }
        var total = files.reduce(0) { $0 + size($1) }
        files.sort { mtime($0) < mtime($1) }   // oldest first
        var i = 0
        while total > maxBytes, i < files.count { total -= size(files[i]); try? fm.removeItem(at: files[i]); i += 1 }
    }
}
```
> `isCached` uses `Date()`-free path math (no `Date.now` in the hot path issue here — this is app code, not a workflow script, so `Date()` is fine). Note: the LRU uses file mtime as the recency signal; `touch` on hit refreshes it.
- [ ] **Step 4: Run — pass.** Commit: `feat(ios): RemoteFileCache — LRU on-disk cache for downloaded provider files`.

---

## Task 7: AudioEngine — download remote files before play

**Files:** Modify `Sources/Playback/AudioEngine.swift`; add `Tests/RemotePlaybackPrepTests.swift`.

A remote `Track` (sourceId is a cloud source, `providerFileId != nil`, no playable bookmark) must be downloaded to the cache first. Add an async preparation that resolves a local URL; local/bundled tracks keep the synchronous path.

- [ ] **Step 1:** Add a `RemoteResolver` seam to AudioEngine: a closure `var remoteURLProvider: ((Track) async -> URL?)?` (set by the app wiring to download via the provider + `RemoteFileCache`). In `play(_:in:context:)`, if `resolveURL(track) == nil` AND `track.providerFileId != nil` AND a `remoteURLProvider` is set, set a new `@Published private(set) var isPreparing = true`, `Task { if let url = await remoteURLProvider(track) { … loadAndStart from url … } }`. Keep the existing synchronous local path otherwise. (Add a private `loadAndStart(url:track:)` overload that takes a resolved URL so both paths share scheduling.)
- [ ] **Step 2:** Unit test the DECISION logic (not the network): a test that, given a Track with `providerFileId` set and `bookmark`/`bundledName` nil, `AudioEngine.needsRemotePrep(track)` returns true; for a local track returns false. (Extract a tiny pure `needsRemotePrep` so it's testable without AVAudioEngine.)
```swift
import XCTest
@testable import NanoMeters
@MainActor final class RemotePlaybackPrepTests: XCTestCase {
    func test_needsRemotePrep_trueForCloudTrackWithoutLocalFile() {
        let cloud = Track(title:"x",artist:"",album:""); cloud.providerFileId = "a1"; cloud.sourceId = "gdrive"
        XCTAssertTrue(AudioEngine.needsRemotePrep(cloud))
        let local = Track(title:"y",artist:"",album:"", bundledName:"biljam.mp3")
        XCTAssertFalse(AudioEngine.needsRemotePrep(local))
    }
}
```
- [ ] **Step 3: Implement** `static func needsRemotePrep(_ t: Track) -> Bool { t.bundledName == nil && t.bookmark == nil && t.providerFileId != nil }` and the prepare path. Keep `isPreparing` observable so the UI can show a "downloading" state. Build + test.
- [ ] **Step 4: Run — pass.** Commit: `feat(ios): AudioEngine downloads remote tracks to cache before play`.

---

## Task 8: ASWebAuthenticationSession shell + SourcesManager.connectOAuth

**Files:** Create `OAuth/WebAuthSession.swift`; modify `Sources/Sources/SourcesManager.swift`.

- [ ] **Step 1: WebAuthSession** — a thin async wrapper over `ASWebAuthenticationSession` (ephemeral) that opens `authorizeURL`, returns the `code` from the `state`-verified callback URL. Conform to `ASWebAuthenticationPresentationContextProviding`. This is the INTERACTIVE piece (manual verify). Signature: `func authorize(url: URL, callbackScheme: String, expectedState: String) async throws -> String` (returns the auth `code`).
- [ ] **Step 2: SourcesManager.connectOAuth** — `func connectOAuth(kind: SourceKind, config: OAuthConfig, web: WebAuthSession, client: OAuthClient, tokenStore: TokenStore) async throws`: generate PKCE+state → `web.authorize(authorizeURL)` → `client.exchange(code, verifier)` → `tokenStore.save(token, account: kind.rawValue)` → `connect(kind:, authRef: kind.rawValue)` with `state = .noRoots`. Add an `accessToken(for:)` that loads from the store and refreshes via `client.refresh` when `isExpiring` (serialized), persisting the new token — this is the `accessToken` supplier handed to `GoogleDriveProvider`.
- [ ] **Step 3:** Unit-test `accessToken(for:)` refresh path with `InMemoryTokenStore` + `MockHTTPClient` (an expiring token triggers a refresh and the refreshed token is persisted). Build + test.
- [ ] **Step 4: Commit** — `feat(ios): ASWebAuthenticationSession shell + SourcesManager.connectOAuth/accessToken`.

---

## Task 9: Settings — Drive Connect + Add Root (Drive folder browser)

**Files:** Modify `Sources/Screens/SourcesSettingsView.swift`.

- [ ] **Step 1:** In Add Source, Google Drive's row: if `OAuthConfig.google.isConfigured` → a **Connect** pill that runs `connectOAuth` (shows a spinner; on success pushes the source detail). If NOT configured → a disabled row "Needs Google client ID (see setup)" instead of "Coming soon".
- [ ] **Step 2: Add Root for Drive** — a Drive folder browser: list folders under "root" (`DriveAPIClient.listChildren` filtered to folders), let the user drill + pick a folder; on pick, `GoogleDriveProvider.enumerate(providerFolderId: picked, rootId: picked, rootName:)` → `SourcesManager.applyEnumeration(..., providerFolderId: picked, rootNodeId: picked)`. Set the source `.connected`.
- [ ] **Step 3: Build + unit suite green.** Commit: `feat(ios): Settings Drive Connect (OAuth) + Drive folder root picker`.

> The live OAuth + real Drive listing is MANUAL verification (needs the client ID + a real Google account). The Task-10 mock covers the flow shape headlessly.

---

## Task 10: MockSourceProvider + headless Drive-flow UI test

**Files:** Create `Sources/MockSourceProvider.swift`, `UITests/DriveMockFlowUITests.swift`.

- [ ] **Step 1: MockSourceProvider** — conforms to `SourceProvider`, `kind = .gdrive`, `enumerate(...)` returns a fixed 2-level `EnumerationResult` (a "Mock Drive" root → "House"/"DnB" with a couple of tracks). Add a DEBUG launch-argument hook (`-mock-drive`) in `NanoMetersApp`/`RootView` that, on first launch, `SourcesManager.connect(kind: .gdrive)` + `applyEnumeration(mockResult, sourceId:"gdrive", rootName:"Mock Drive", rootNodeId:"mock-root", rootBookmark:nil, providerFolderId:"mock-root")`, so the Library shows a Google Drive source with a real browsable tree — no network/OAuth.
- [ ] **Step 2: XCUITest** `DriveMockFlowUITests` (launch with `-mock-drive`): assert the Library root shows a `sourceRow-gdrive` ("Google Drive"); drill it → see the mock folders; drill a folder → see a mock track; scoped-search within it; open the track's `⋯` → `goToSource` works. This proves the entire source pipeline end-to-end against a provider, independent of Google.
- [ ] **Step 3:** Run on the Nano sim; iterate; full UI bundle green. Commit: `test(ios): MockSourceProvider + headless Drive-flow XCUITest`.

---

## Task 11: Wire the real GoogleDriveProvider + document the one-step credential integration

**Files:** Modify `apps/nano-ios/project.yml`, `Sources/Sources/SourcesManager.swift` (provider registry); create `docs/google-drive-setup.md`.

- [ ] **Step 1: project.yml** — add to `targets.NanoMeters.info.properties`: `GoogleOAuthClientID: "YOUR_GOOGLE_IOS_CLIENT_ID"` and a `CFBundleURLTypes` entry with a placeholder reversed-client-id scheme `com.googleusercontent.apps.YOUR_GOOGLE_IOS_CLIENT_ID`. Comment that BOTH are replaced with the user's real client id.
- [ ] **Step 2: Provider registry** — `SourcesManager.provider(for: SourceKind, accessToken:)` returns `LocalSourceProvider`/`GoogleDriveProvider(api: DriveAPIClient(http: URLSessionHTTPClient()), accessToken:)` based on kind; the Settings/AudioEngine wiring uses it. The `remoteURLProvider` on AudioEngine downloads via `DriveAPIClient.mediaRequest` + `RemoteFileCache` using `accessToken(for: "gdrive")`.
- [ ] **Step 3: docs/google-drive-setup.md** — the exact Google Cloud Console click-path (project → OAuth consent screen External + test user → iOS OAuth client with bundle id `com.willeasp.nanometers.ios` → copy client id) and the TWO edits to make it live: set `GoogleOAuthClientID` and the `CFBundleURLTypes` scheme in `project.yml`, then `xcodegen generate`. Note: free Apple team is fine; the scheme is the reversed client id.
- [ ] **Step 4: Build + full suite green** (with the placeholder client id, Drive Connect shows "needs setup"; everything else green). Commit: `feat(ios): wire real GoogleDriveProvider behind the client-id seam + setup doc`.

---

## Phase 5 acceptance
- [ ] PKCE, token store + refresh, Drive list parsing, Drive enumeration, and the LRU cache are all unit-tested (mocked HTTP, no network).
- [ ] The full source pipeline (connect → root → browse → search → Go-to-Source → play) is XCUITest-verified against `MockSourceProvider` headlessly.
- [ ] AudioEngine downloads a remote track to the cache and plays it via the existing local path (waveform/LUFS unchanged); cache hits skip re-download.
- [ ] The ONLY missing piece for live Drive is the user's client id (set in `project.yml`); `docs/google-drive-setup.md` gives the exact steps. Live consent + a real Drive folder are the manual verification.
- [ ] Full unit + UI suites green on the Nano sim.

**This is the last phase.** After it: a final full-branch adversarial review + `finishing-a-development-branch`.
