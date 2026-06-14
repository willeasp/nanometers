# OneDrive Source — Design Spec

**Date:** 2026-06-14
**Status:** Approved-pending-user-review
**Worktree/branch:** `onedrive`

## Goal

Add Microsoft OneDrive as a connectable cloud source in nano-ios, reaching parity with the existing
Google Drive integration: OAuth connect → pick a root folder → enumerate the subtree into the Library
index → stream-download tracks for playback + waveform/LUFS analysis, with on-disk LRU caching.

## Context: this is net-new, not a fix

`SourceKind.onedrive` already exists in the enum (label/short/tint/order all defined), but it is a
**"Coming soon" placeholder** — the Add-Source UI greys it out and `SourcesManager.provider(for:)`
`assertionFailure`s on it. Nothing about OneDrive works today. This spec builds it by mirroring the
Google Drive stack, which was deliberately built provider-agnostic at the `SourceProvider` /
`OAuthConfig` / `SourcesManager` layer.

## Decisions (locked)

- **Account types:** personal Microsoft accounts only → `/consumers` authority endpoint.
- **Sequencing:** build + unit-test the full stack now; the user registers the Azure/Entra app and
  supplies the client ID later for live sign-in. No Azure registration blocks the build.
- **Download transport:** Graph `GET /me/drive/items/{id}/content` with a Bearer token (URLSession
  follows the 302 to the pre-authed download URL). Mirrors `DriveAPIClient.mediaRequest`; reuses the
  same 401 → forced-refresh → retry-once pattern. (We do *not* use the `@microsoft.graph.downloadUrl`
  from the list response — it expires and complicates the refresh-retry path.)
- **Secret hygiene:** the Microsoft client ID lives only in the gitignored `Secrets.xcconfig`, exactly
  like the Google one. The committed tree holds only `$(MICROSOFT_OAUTH_CLIENT_ID)` placeholders.

## Reused as-is (no changes)

- OAuth machinery: `PKCE`, `KeychainTokenStore`, `TokenRefreshCoordinator`, `WebAuthSession`,
  `HTTPClient`, the `OAuthClient.exchange`/`refresh`/`token` decode (Microsoft returns the same
  `access_token` / `refresh_token` / `expires_in` shape).
- `SourcesManager.connectOAuth` / `accessToken` / `markReachable` / `degradedState` — already keyed by
  `kind.rawValue`, provider-agnostic.
- `RemoteFileCache`, download-first playback (`AudioEngine.loadFromURL` / `needsRemotePrep`),
  `WaveformStore.analyzeDownloaded`, the `Track.providerFileId` / `sourceId` model.
- The `SourceProvider` protocol, the Library/index/Settings drill-down.

## New & changed components

### 1. `OAuthConfig` generalization (small refactor)
`OAuthClient.authorizeURL` currently hardcodes Google's `access_type=offline` + `prompt=consent`
(`OAuthClient.swift:14`). Microsoft does not use `access_type` and gets its refresh token from the
`offline_access` *scope*. Lift provider-specific authorize params into config:

- Add `var extraAuthParams: [String: String]` to `OAuthConfig`.
- `authorizeURL` appends `config.extraAuthParams` instead of the hardcoded Google pair.
- `OAuthConfig.google.extraAuthParams = ["access_type": "offline", "prompt": "consent"]` (unchanged behaviour).
- New `OAuthConfig.microsoft`:
  - `authEndpoint  = https://login.microsoftonline.com/consumers/oauth2/v2.0/authorize`
  - `tokenEndpoint = https://login.microsoftonline.com/consumers/oauth2/v2.0/token`
  - `scopes        = ["Files.Read", "offline_access"]`
  - `clientID`     from Info.plist `MicrosoftOAuthClientID` (placeholder until set)
  - `redirectScheme = msauth.com.willeasp.nanometers.ios` (the ASWebAuthenticationSession callback scheme)
  - `extraAuthParams = ["prompt": "select_account"]`
  - `isConfigured` = same non-empty / non-placeholder check.
- **`redirectURI` becomes provider-specific (not a shared computed format).** Today it is the computed
  `"\(redirectScheme):/oauth"` (Google's single-slash custom-scheme format). Microsoft/MSAL convention is
  `msauth.<bundleid>://auth` (double slash, `auth` host) and it must match the Entra registration exactly.
  Make `redirectURI` a stored field on `OAuthConfig`: Google = `com.googleusercontent.apps.<id>:/oauth`
  (unchanged), Microsoft = `msauth.com.willeasp.nanometers.ios://auth`. `redirectScheme` stays the
  scheme-only value passed to `WebAuthSession` as the callback scheme.
- Keep the `-force-drive-unconfigured` DEBUG hook working, and extend the test seam so OneDrive can be
  forced unconfigured too (e.g. `-force-cloud-unconfigured` forces *both* gdrive + onedrive to placeholder).

### 2. `GraphAPIClient` (mirror `DriveAPIClient`)
New file `Sources/Sources/OneDrive/GraphAPIClient.swift`.

- `GraphItem: Decodable { id; name; folder?; file? }` where `folder` presence ⇒ folder, `file.mimeType` ⇒ track.
- Audio filter identical in spirit to Drive: `file.mimeType` audio/* OR known audio extension
  (reuse `DriveAudioMime` — rename to a shared `AudioMime` or keep a parallel helper; spec: extract a
  shared `AudioMime` used by both clients).
- `listChildren(parentId:accessToken:)` → `GET /me/drive/root/children` when `parentId == "root"`,
  else `GET /me/drive/items/{parentId}/children`, query `$top=1000`, follow `@odata.nextLink` until nil.
- `contentRequest(fileId:accessToken:)` → `GET /me/drive/items/{id}/content`, `Authorization: Bearer`.
- `GraphError` enum: `.unauthorized` (401), `.http(Int)`, `.badResponse` — mirrors `DriveError`.

### 3. `OneDriveProvider: SourceProvider` (mirror `GoogleDriveProvider`)
New file `Sources/Sources/OneDrive/OneDriveProvider.swift`.

- `kind = .onedrive`; `enumerate(...)` DFS-walks from `rootId` (the RootFolder's providerFolderId; the
  sentinel `"root"` for the drive root), with the same `visited` cycle-guard, depth ≤ 64 backstop, and
  401 → `accessToken(forceRefresh:true)` → retry-once-per-folder behaviour as `GoogleDriveProvider`.
- Emits the same `FolderDescriptor` / `TrackDescriptor` (cloud: `bookmark = nil`, `providerFileId = id`).

### 4. Provider factory
`SourcesManager.provider(for:)` — add `.onedrive` → `OneDriveProvider(api: GraphAPIClient(http:
URLSessionHTTPClient()), accessToken:)`. Dropbox stays in the unreachable/assert branch.

### 5. Remote download closure
`RootView.makeRemoteURLProvider` is `.gdrive`-only today (`guard kind == .gdrive`, hardcoded
`OAuthConfig.google`, `DriveAPIClient.mediaRequest`). Generalize:

- Resolve `(config, downloadRequest)` per `kind`: `.gdrive` → `.google` + `DriveAPIClient.mediaRequest`;
  `.onedrive` → `.microsoft` + `GraphAPIClient.contentRequest`. Other kinds → return nil.
- Assemble the provider when *any* cloud config `isConfigured` (currently gated on
  `OAuthConfig.google.isConfigured`).

### 6. Settings UI un-gate (`SourcesSettingsView`)
The `AddSourceRow` gates `isDriveConfigured` / `isDriveNotConfigured` are gdrive-only; the Connect
button, `ConnectDetailBridge`, and the `.needsReauth` Reconnect (line ~100) hardcode `.gdrive`/`.google`.

- Introduce a helper `oauthConfig(for kind: SourceKind) -> OAuthConfig?` (gdrive→.google,
  onedrive→.microsoft, else nil). An OAuth-cloud kind is one where this returns non-nil.
- Replace the gdrive-specific booleans with `isOAuthConfigured` / `isOAuthNotConfigured` driven by that
  helper, so OneDrive renders **Connect** (configured) / **Needs setup** (not configured) instead of
  falling into the **Coming soon** `else`. Dropbox keeps **Coming soon**.
- Parameterize the Connect button's `connectOAuth(kind:config:...)`, `ConnectDetailBridge(kind:)`, and
  the not-configured sub-label (Drive: "Add your Google client ID …"; OneDrive: "Add your Microsoft
  client ID (see docs/onedrive-setup.md)").

### 7. Root-folder picker
`DriveFolderPicker` (opened when `kind == .gdrive`, browses Drive folders via the API to pick a root)
must serve OneDrive too. Generalize it to take the `kind` + the matching "list folders" call (Graph for
OneDrive, Drive for gdrive), or add a thin OneDrive variant sharing the same view. The picked folder's
provider item id becomes the `RootFolder.providerFolderId`.

### 8. Secrets / Info.plist / docs
- `Secrets.example.xcconfig` + `Secrets.xcconfig` + `Config.xcconfig`: add `MICROSOFT_OAUTH_CLIENT_ID`
  and `MICROSOFT_OAUTH_REDIRECT_SCHEME` (default `msauth.com.willeasp.nanometers.ios`).
- `project.yml`: Info.plist `MicrosoftOAuthClientID: "$(MICROSOFT_OAUTH_CLIENT_ID)"`; add
  `$(MICROSOFT_OAUTH_REDIRECT_SCHEME)` to `CFBundleURLTypes`. Run `xcodegen generate`.
- `docs/onedrive-setup.md`: Entra app registration (Mobile/desktop platform, redirect
  `msauth.com.willeasp.nanometers.ios://auth`, delegated `Files.Read` + `offline_access`, personal
  accounts only, **no client secret** — public PKCE client), then fill `Secrets.xcconfig` + regenerate.

## Tests

- `GraphAPIClientTests`: parse children (folder vs file facet, audio filter), `@odata.nextLink`
  pagination, 401 → `.unauthorized`.
- `OneDriveProviderTests`: walk a mocked tree (mock `HTTPClient`), cycle + depth guards, 401 retry.
- `OAuthConfigTests`: `.microsoft` endpoints/scopes/redirectScheme; `extraAuthParams` plumbed into
  `authorizeURL` (Google still emits access_type/prompt; Microsoft emits prompt=select_account, no access_type).
- `SourcesSettingsUITests`: OneDrive now shows **Needs setup** (forced unconfigured), Dropbox still
  **Coming soon**. Update the existing assertions accordingly.

## Out of scope

- Streaming/progressive playback (still download-first for everyone; tracked separately).
- Dropbox (stays "Coming soon").
- Work/school Microsoft accounts (`/organizations`, `/common`) — personal-only per decision.
- Shared/"shared with me" OneDrive items — only the user's own drive subtree.

## Risks / nuances

- Microsoft v2.0 token endpoint for public clients is PKCE-only (no secret) — the existing
  `OAuthClient.token` form sends no secret, so it's already correct.
- `offline_access` scope is mandatory for a refresh token on personal accounts (in scopes above).
- `/me/drive/items/root` vs `/me/drive/root` — use the `"root"` sentinel → `/me/drive/root/children`.
- Graph `/content` 302-redirects to a storage URL; URLSession follows it by default. Verify the
  redirected request does not re-send the Bearer to the storage host (URLSession drops auth on
  cross-host redirect by default — fine, the storage URL is pre-authed).
