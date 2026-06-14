# Library & Sources — Implementation Summary

Status as of the autonomous build (2026-06-14). Branch: **`library-and-sources`**. All 6 phases implemented, ~75 commits, **139 unit + 12 UI tests green** on the iPhone 16 Pro (Nano) simulator.

The design spec is `docs/superpowers/specs/2026-06-14-library-and-sources-design.md`; the per-phase plans are `docs/superpowers/plans/2026-06-14-library-sources-phaseN-*.md`.

---

## What you need to do (the only manual steps)

1. **Create a Google Cloud OAuth client** and drop the client ID into the app — full click-path in **`docs/google-drive-setup.md`**. Two synced edits in `apps/nano-ios/project.yml` (`GoogleOAuthClientID` + the reversed-client-id `CFBundleURLTypes` scheme), then `xcodegen generate`. Free Apple team is fine; PKCE means no client secret.
2. **One on-device sign-in** to verify the live OAuth consent → token in Keychain → a real Drive folder enumerates → a Drive track downloads, plays, and shows waveform/LUFS. (The consent screen can't run headless, so this leg is manual — everything else is automated.)

Until you set the client ID, `OAuthConfig.google.isConfigured` is `false`, so Drive shows a **"needs setup"** state and every live Drive path is sealed — the app builds and all non-Drive features work.

**Want to see the whole Drive pipeline working right now, without Google?** Launch with the `-mock-drive` argument (a DEBUG hook) — it connects a fake "Google Drive" source with a browsable tree, so you can browse/search/Go-to-Source/play against a provider with no network. This is what `DriveMockFlowUITests` drives headlessly.

---

## What was built (by phase)

1. **Data model + migration + index** — `Source`/`RootFolder`/`FolderNode` SwiftData models (string-id keyed, matching the existing `Playlist.itemIDs` pattern); `Track` gained `sourceId`/`providerFileId`/`folderId`. `SourcesMigration` attaches pre-existing tracks to a seeded "On My iPhone" source. `LibraryIndex` derives the reachable set, recursive counts, and trackId→path (cycle-guarded, deterministic, distinct counts).
2. **Folder-browser Library** — one `LibraryNav` state object drives the tab; `LibraryBrowse` is a pure, tested resolver producing the render model (sources/folders/tracks/breadcrumbs/recursive Play-All). Root = All Songs + connected sources (canonical order); drill with tappable breadcrumb, labeled back, tab-re-tap-to-root, "Play"/"Play All", empty states.
3. **Scoped search + Go-to-Source + Playing-from** — recursive search over the local index with relative folder-path labels (clears on nav); Go-to-Source from any `⋯` (playlist/queue/search/Now Playing) navigates + flashes the row; folder-aware "Playing from" labels.
4. **Settings Sources manager + provider abstraction** — main → source detail → add source → add root; `SourceProvider` protocol; `DirectoryEnumerator` (local/iCloud folder trees, deterministic SHA-256 ids, symlink-guarded); `SourcesManager` (connect/add-root/remove-root/disconnect, idempotent upsert). Enumerated local files play via the **root folder's** security-scoped bookmark + a relative path (per-file bookmarks aren't security-scoped on iOS).
5. **OAuth + Google Drive + streaming** — Authorization-Code + **PKCE (S256)** via ephemeral `ASWebAuthenticationSession`; tokens in the **Keychain** only (`kSecAttrAccessibleAfterFirstUnlock`), never logged/UserDefaults; a shared `TokenRefreshCoordinator` (coalesced, clears on failure, 401→refresh+retry, `needsReauth` on failure); Drive REST v3 enumeration (paginated, cycle-guarded, audio-by-extension); `RemoteFileCache` (LRU, concurrent-download dedup, eviction never drops the just-fetched file); `AudioEngine` downloads cloud tracks to the cache then plays them via the existing local path (waveform/LUFS unchanged), with a load-generation guard so a slow download can't start the wrong track. Disconnect best-effort revokes + deletes creds.

Every phase got an adversarial multi-agent review + a fix pass. Notable bugs caught and fixed: `LibraryIndex` cycle/root-resolution, enumerated-local playback (folder vs per-file bookmark), non-deterministic `hashValue` ids → SHA-256, duplicate search `ForEach` ids, sticky Go-to-Source highlight across tabs, Drive enumeration recursion on shortcuts, cache concurrent-download race, wrong-track playback on rapid switches, and the full OAuth token lifecycle (refresh coalescing/`needsReauth`/disconnect revoke).

---

## As-built deviations (intentional)

- **Per-file import** moved off the locked Library header (search + gear only, per handoff) to the All Songs view.
- **Local enumerated tracks** store the relative path in `Track.providerFileId` and the root bookmark in `Track.folderBookmark`; cloud tracks have `providerFileId` only (no folder bookmark) → `AudioEngine.needsRemotePrep` routes them through the download cache.
- The new models are **string-id keyed** (no SwiftData relationships), superseding the spec table's `Source.roots: [RootFolder]` relationship — matches the existing `Playlist.itemIDs` choice.

## Known minor limitations (deferred, documented)

- **iCloud non-resident files**: placeholders are detected + enumerated, but on-demand download (`startDownloadingUbiquitousItem`) on first play is a TODO — non-resident iCloud tracks won't materialize automatically yet. (Google Drive, the headline source, fully streams.)
- The OAuth redirect URI uses `scheme:/oauth` (single slash); functionally fine for Google (same string to `/authorize` and `/token`) — worth a glance during the manual sign-in.

## Verifying

```sh
cd apps/nano-ios && xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,name=iPhone 16 Pro'
```
Unit tests cover PKCE/token/refresh, Drive enumeration + parsing, the LRU cache, `LibraryIndex`/`LibraryNav`/`LibraryBrowse`, migration, and availability. UI tests cover the folder browser, scoped search, Go-to-Source, Settings Sources, and the full mock-Drive flow.
