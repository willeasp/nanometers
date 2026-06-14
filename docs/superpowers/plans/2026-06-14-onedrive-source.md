# OneDrive Source Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement
> this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Microsoft OneDrive as a connectable cloud source in nano-ios at parity with Google Drive.

**Architecture:** Mirror the provider-agnostic Drive stack — a `GraphAPIClient` + `OneDriveProvider`
over Microsoft Graph, an `OAuthConfig.microsoft` over the `/consumers` authority, and generalization of
the handful of `.gdrive`-hardcoded seams (provider factory, download closure, Settings UI, root picker).
Personal Microsoft accounts only. Download-first playback through the existing `RemoteFileCache` +
waveform/LUFS path. Build now; live Azure registration supplied later.

**Tech Stack:** Swift / SwiftUI, SwiftData, Microsoft Graph v1.0, OAuth2 auth-code + PKCE, XcodeGen.

**Reference (read these before each task):** `Sources/Sources/Drive/DriveAPIClient.swift`,
`Sources/Sources/Drive/GoogleDriveProvider.swift`, `Sources/Sources/OAuth/OAuthConfig.swift`,
`Sources/Sources/OAuth/OAuthClient.swift`, `Sources/Sources/SourcesManager.swift`,
`Sources/RootView.swift` (remote URL provider), `Sources/Screens/SourcesSettingsView.swift`.
Spec: `docs/superpowers/specs/2026-06-14-onedrive-source-design.md`.

**Test command (Nano simulator — UDID is mandatory, `name=` resolves to the wrong sim):**
```sh
cd apps/nano-ios && xcodegen generate && \
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=28DD8D81-668A-4887-98E8-BFE3CC625596' \
  -only-testing:NanoMetersTests 2>&1 | tail -40
```

---

### Task 1: OAuthConfig generalization + AudioMime extraction

**Files:**
- Modify: `Sources/Sources/OAuth/OAuthConfig.swift`
- Modify: `Sources/Sources/OAuth/OAuthClient.swift:6-17` (authorizeURL)
- Modify: `Sources/Sources/Drive/DriveAPIClient.swift` (extract `AudioMime`)
- Create: `Sources/Sources/AudioMime.swift`
- Test: `Tests/OAuthConfigTests.swift` (new), update `Tests/OAuthClientTests.swift`

- [ ] **Step 1:** Extract the Drive audio helper into a shared `AudioMime` enum (move `isAudio` +
  `isAudioByExtension` + the extension set out of `DriveAudioMime` in DriveAPIClient.swift into
  `Sources/Sources/AudioMime.swift`). Replace `DriveAudioMime` references with `AudioMime`. Run the
  existing Drive tests to confirm no regression.

- [ ] **Step 2:** Add to `OAuthConfig`: `var extraAuthParams: [String: String]` and change `redirectURI`
  from the computed `"\(redirectScheme):/oauth"` to a **stored** `var redirectURI: String`.
  Update `OAuthConfig.google` to set `redirectURI = reversedScheme(...)+":/oauth"` (preserve current
  value) and `extraAuthParams = ["access_type": "offline", "prompt": "consent"]`.

- [ ] **Step 3:** In `OAuthClient.authorizeURL`, replace the hardcoded `access_type`/`prompt` pair with
  `config.extraAuthParams.map { URLQueryItem(name: $0.key, value: $0.value) }` appended to the items.
  (Keep deterministic ordering for tests — sort by key.)

- [ ] **Step 4:** Add `OAuthConfig.microsoft`:
  ```swift
  static let microsoftPlaceholder = "YOUR_MICROSOFT_CLIENT_ID"
  static var microsoft: OAuthConfig {
      var id = (Bundle.main.object(forInfoDictionaryKey: "MicrosoftOAuthClientID") as? String) ?? microsoftPlaceholder
      #if DEBUG
      if ProcessInfo.processInfo.arguments.contains("-force-cloud-unconfigured") { id = microsoftPlaceholder }
      #endif
      let scheme = (Bundle.main.object(forInfoDictionaryKey: "MicrosoftOAuthRedirectScheme") as? String)
          ?? "msauth.com.willeasp.nanometers.ios"
      return OAuthConfig(
          clientID: id, redirectScheme: scheme, redirectURI: "\(scheme)://auth",
          authEndpoint: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize")!,
          tokenEndpoint: URL(string: "https://login.microsoftonline.com/consumers/oauth2/v2.0/token")!,
          scopes: ["Files.Read", "offline_access"],
          extraAuthParams: ["prompt": "select_account"])
  }
  ```
  Keep a **single** `isConfigured` that treats *either* placeholder (and empty) as unconfigured, so
  both providers use the same accessor (no `isMicrosoftConfigured`):
  ```swift
  var isConfigured: Bool {
      !clientID.isEmpty && clientID != Self.placeholder && clientID != Self.microsoftPlaceholder
  }
  ```
  Also extend the DEBUG force hook: `-force-cloud-unconfigured` forces *both* providers to their
  placeholder; keep `-force-drive-unconfigured` working (forces Google only) for the existing test until
  Task 10 migrates it.

- [ ] **Step 5:** Tests — `OAuthConfigTests`: assert `.microsoft` endpoints/scopes/redirectURI/scheme and
  `extraAuthParams == ["prompt": "select_account"]`; assert `.google.extraAuthParams` still has
  access_type+prompt. `OAuthClientTests`: assert `authorizeURL(for: .microsoft)` contains
  `prompt=select_account`, `scope=Files.Read offline_access` (encoded), and **no** `access_type`;
  assert the Google URL still contains `access_type=offline`.

- [ ] **Step 6:** Run `OAuthConfigTests` + `OAuthClientTests` (green). Commit:
  `feat(ios): generalize OAuthConfig for multiple providers (Microsoft alongside Google)`.

---

### Task 2: GraphAPIClient (Microsoft Graph children + content)

**Files:**
- Create: `Sources/Sources/OneDrive/GraphAPIClient.swift`
- Test: `Tests/GraphAPIClientTests.swift`

- [ ] **Step 1 (test-first):** `GraphAPIClientTests` — feed `GraphAPIClient.parseChildren(_:)` a JSON
  fixture with a folder (has `"folder": {...}`), an audio file (`"file": {"mimeType":"audio/mpeg"}`), a
  non-audio file (`application/pdf`), an `application/octet-stream` file named `song.flac`, and a
  `@odata.nextLink`. Assert the folder + the two audio files are kept, the pdf dropped, and nextLink
  parsed. Run → fails (no symbol).

- [ ] **Step 2:** Implement:
  ```swift
  struct GraphItem: Decodable, Equatable { var id: String; var name: String
      struct FileFacet: Decodable, Equatable { var mimeType: String? }
      var folder: GraphFolderFacet?; var file: FileFacet?
      struct GraphFolderFacet: Decodable, Equatable { var childCount: Int? } }
  enum GraphError: Error, LocalizedError { case unauthorized; case http(Int); case badResponse }
  struct GraphListPage: Equatable { var folders: [GraphItem]; var tracks: [GraphItem]; var nextLink: String? }
  struct GraphAPIClient {
      let http: HTTPClient
      static func parseChildren(_ data: Data) throws -> GraphListPage { /* decode {value:[GraphItem], @odata.nextLink} */ }
      static func childrenRequest(parentId: String, accessToken: String) -> URLRequest { /* root sentinel → /me/drive/root/children else /me/drive/items/{id}/children?$top=1000&$select=id,name,folder,file */ }
      static func nextRequest(nextLink: String, accessToken: String) -> URLRequest
      static func contentRequest(fileId: String, accessToken: String) -> URLRequest // GET /me/drive/items/{id}/content, Bearer, NO Range header
      func listChildren(parentId: String, accessToken: String) async throws -> (folders: [GraphItem], tracks: [GraphItem]) // follow @odata.nextLink; 401 → GraphError.unauthorized
  }
  ```
  Folder = `item.folder != nil`. Track = `item.folder == nil && (AudioMime.isAudio(item.file?.mimeType ?? "") || AudioMime.isAudioByExtension(item.name))`. `@odata.nextLink` is an absolute URL → GET as-is with Bearer.

- [ ] **Step 3:** Run `GraphAPIClientTests` (green). Commit:
  `feat(ios): GraphAPIClient — OneDrive children listing + content download over MS Graph`.

---

### Task 3: OneDriveProvider (subtree walk)

**Files:**
- Create: `Sources/Sources/OneDrive/OneDriveProvider.swift`
- Test: `Tests/OneDriveProviderTests.swift`

- [ ] **Step 1 (test-first):** Mirror `GoogleDriveProvider` tests. With a mock `HTTPClient` returning a
  small tree (root → 1 subfolder + 1 track; subfolder → 1 track), assert `enumerate(... rootId:"root")`
  yields 2 `FolderDescriptor`s + 2 `TrackDescriptor`s with `bookmark==nil`, `providerFileId==id`. Add a
  cycle case (child points back to root → visited guard) and a 401-then-success case (first
  `listChildren` throws `.unauthorized`, `accessToken(true)` path retries).

- [ ] **Step 2:** Implement `OneDriveProvider: SourceProvider` mirroring `GoogleDriveProvider` exactly —
  same `walk` signature, `visited` set, `depth <= 64`, `accessToken(false)` then on `GraphError.unauthorized`
  `accessToken(true)` retry-once. `kind = .onedrive`. Use `GraphAPIClient.listChildren`.

- [ ] **Step 3:** Run `OneDriveProviderTests` (green). Commit:
  `feat(ios): OneDriveProvider — Graph subtree enumeration mirroring Drive`.

---

### Task 4: Provider factory wiring

**Files:** Modify `Sources/Sources/SourcesManager.swift:148-162`

- [ ] **Step 1:** In `provider(for:)`, add `.onedrive` → `OneDriveProvider(api: GraphAPIClient(http:
  URLSessionHTTPClient()), accessToken: accessToken)`. Leave `.dropbox` in the assert branch.
- [ ] **Step 2:** `cargo`-equivalent: build the test target (it compiles SourcesManager). Commit:
  `feat(ios): register OneDriveProvider in the source provider factory`.

---

### Task 5: Remote download closure generalization

**Files:** Modify `Sources/RootView.swift:128-210` (`makeRemoteURLProvider`)

- [ ] **Step 1:** Replace `guard kind == .gdrive` with a per-kind resolution of
  `(config: OAuthConfig, makeRequest: (_ fileId: String, _ token: String) -> URLRequest)`:
  `.gdrive` → `(.google, DriveAPIClient.mediaRequest(fileId:accessToken:offset:0))`;
  `.onedrive` → `(.microsoft, GraphAPIClient.contentRequest(fileId:accessToken:))`; else return nil.
  Keep the existing 401→forceRefresh→retry-once download logic, now using `makeRequest`.
- [ ] **Step 2:** Change the assembly gate (currently `OAuthConfig.google.isConfigured`) to assemble when
  `OAuthConfig.google.isConfigured || OAuthConfig.microsoft.isConfigured`.
- [ ] **Step 3:** Build test target (compiles RootView). Commit:
  `feat(ios): route cloud downloads per source kind (OneDrive via Graph /content)`.

---

### Task 6: Settings UI un-gate

**Files:** Modify `Sources/Screens/SourcesSettingsView.swift` (AddSourceRow ~365-516; needsReauth ~100;
ConnectDetailBridge ~403; the Connect button ~459-497)

- [ ] **Step 1:** Add a helper `func oauthConfig(for kind: SourceKind) -> OAuthConfig?`
  (`.gdrive → .google`, `.onedrive → .microsoft`, else `nil`) and `isConfigured` using the
  provider-appropriate check. Replace `isDriveConfigured`/`isDriveNotConfigured` with
  `isOAuthConfigured`/`isOAuthNotConfigured` driven by that helper, so OneDrive renders **Connect** /
  **Needs setup** instead of falling to **Coming soon**. Dropbox (no config) keeps **Coming soon**.
- [ ] **Step 2:** Parameterize the Connect button's `connectOAuth(kind:config:...)`, the
  `ConnectDetailBridge(kind:)`, the `.needsReauth` Reconnect (line ~100, currently `kind == .gdrive &&
  OAuthConfig.google.isConfigured`), and the not-configured sub-label per kind (Drive: "Add your Google
  client ID (see docs/google-drive-setup.md)"; OneDrive: "Add your Microsoft client ID (see
  docs/onedrive-setup.md)").
- [ ] **Step 3:** Build app target. Manually confirm in the Nano sim that OneDrive shows "Needs setup"
  (no Microsoft secret yet) and Drive shows "Connect" (Google secret present). Commit:
  `feat(ios): un-gate OneDrive in Add Source — Connect/Needs-setup per OAuth provider`.

---

### Task 7: Root-folder picker generalization

**Files:** Modify `Sources/Screens/SourcesSettingsView.swift` (`DriveFolderPicker` ~605-790 and its
`kind == .gdrive` call sites ~176, ~750, ~777)

- [ ] **Step 1:** Read the existing `DriveFolderPicker` to learn how it lists Drive folders (via the
  provider/API + access token). Generalize it to a `CloudFolderPicker` that takes the `kind` and uses
  the matching list call: gdrive → `DriveAPIClient.listChildren`, onedrive → `GraphAPIClient.listChildren`
  (folders only). The picked folder's provider item id → `RootFolder.providerFolderId`; the OneDrive root
  uses the `"root"` sentinel as the starting point.
- [ ] **Step 2:** Update the `kind == .gdrive` gates that open the picker to open it for any OAuth cloud
  kind (`oauthConfig(for: kind) != nil`).
- [ ] **Step 3:** Build app target (green). Commit:
  `feat(ios): generalize the cloud root-folder picker for OneDrive`.

---

### Task 8: Secrets / Info.plist / project.yml / setup doc

**Files:** Modify `Secrets.example.xcconfig`, `Config.xcconfig`, `project.yml`; create
`docs/onedrive-setup.md`; locally update gitignored `Secrets.xcconfig` (placeholders).

- [ ] **Step 1:** `Secrets.example.xcconfig` + `Config.xcconfig`: add `MICROSOFT_OAUTH_CLIENT_ID` (empty
  default) and `MICROSOFT_OAUTH_REDIRECT_SCHEME = msauth.com.willeasp.nanometers.ios`.
- [ ] **Step 2:** `project.yml` Info.plist: add `MicrosoftOAuthClientID: "$(MICROSOFT_OAUTH_CLIENT_ID)"`
  and `MicrosoftOAuthRedirectScheme: "$(MICROSOFT_OAUTH_REDIRECT_SCHEME)"`; add
  `$(MICROSOFT_OAUTH_REDIRECT_SCHEME)` as a second entry in `CFBundleURLTypes` → `CFBundleURLSchemes`.
  Run `xcodegen generate`.
- [ ] **Step 3:** Write `docs/onedrive-setup.md`: Entra app registration — **Personal Microsoft accounts
  only**; Add platform → **iOS/macOS**, bundle id `com.willeasp.nanometers.ios` → portal computes
  `msauth.com.willeasp.nanometers.ios://auth`; **no client secret** (public PKCE); API permissions →
  Microsoft Graph → Delegated → `Files.Read` + `offline_access`; copy the Application (client) ID into
  `Secrets.xcconfig` as `MICROSOFT_OAUTH_CLIENT_ID`, then `xcodegen generate`. Troubleshooting (AADSTS
  redirect-mismatch → platform must be iOS/macOS, not SPA/Web).
- [ ] **Step 4:** Commit (do NOT add Secrets.xcconfig — gitignored):
  `build(ios): inject Microsoft client id from gitignored xcconfig + OneDrive setup doc`.

---

### Task 9: Refresh-token rotation persistence check

**Files:** Read `Sources/Sources/OAuth/TokenRefreshCoordinator.swift`; modify if needed; test
`Tests/TokenRefreshCoordinatorTests.swift` (or add).

- [ ] **Step 1:** Confirm `TokenRefreshCoordinator.validToken(... forceRefresh:)` writes the refreshed
  `OAuthToken` (with the possibly-rotated `refresh_token`) back to the `TokenStore`. If it doesn't
  persist the new refresh token, fix it (Microsoft rotates on every refresh — a stale refresh token
  strands the source).
- [ ] **Step 2:** Add/extend a test: a mock client whose `refresh` returns a *new* refresh token; assert
  the coordinator saves the new token to the store. Run (green). Commit:
  `fix(ios): persist rotated refresh tokens after refresh (required for OneDrive)`.

---

### Task 10: UI test un-gate + full verification

**Files:** Modify `UITests/SourcesSettingsUITests.swift`

- [ ] **Step 1:** Update the Add-Source assertions: with `-force-cloud-unconfigured`, OneDrive shows
  **Needs setup** (was "Coming soon"); Dropbox still **Coming soon**. Keep Drive **Needs setup**.
  Use `-force-cloud-unconfigured` (forces both) instead of `-force-drive-unconfigured`.
- [ ] **Step 2:** Full run on the Nano sim: `xcodegen generate` then `xcodebuild test` (both
  `NanoMetersTests` + `NanoMetersUITests`) on UDID `28DD8D81-668A-4887-98E8-BFE3CC625596`. All green.
- [ ] **Step 3:** Commit: `test(ios): un-gate OneDrive in Add-Source UI test`.

---

## Final review

After all tasks: run an adversarial code review (parallel reviewers over the diff vs `origin/main`),
fix real findings, then a clean `xcodebuild test` on the Nano sim before handing back for the user's
live Azure registration + on-device test.
