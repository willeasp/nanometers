# Library & Sources — Design Spec

- **Surface:** nano-ios · Library tab + Settings
- **Date:** 2026-06-14
- **Status:** Approved design, pre-implementation
- **Source of truth:** `~/Downloads/Library & Sources - Handoff.html` (v2.0, hi-fi, locked). The base
  data model it extends is `design_handoff_nanometers/04-data-and-sources.md`.
- **Worktree / branch:** `.claude/worktrees/library-and-sources` · `library-and-sources` (off `main` @ 4a204b0)

> **Prototype gap:** the handoff cites "Nanometers Player.html" as the interaction source of truth, but
> both copies on disk predate this feature (grep-empty for `libNav`, `Add Source`, `goToSource`). The
> **handoff HTML doc itself** — with its mockups and per-step `Production` callouts — is therefore the
> authority for the new flows. There is no clickable prototype for them.

---

## 1. What we're building

The Library tab becomes a **folder browser** that mirrors each connected storage service's real folder
tree. Sources are connected/managed **only in Settings**. Scoped recursive search lives in every folder
header. "Go to Source" jumps from any track to the folder that holds it. The first real cloud source is
**Google Drive**, connected via OAuth 2.0 + PKCE, enumerated over Drive REST v3, and streamed by
downloading to an on-disk LRU cache.

### Goals (this round)
- Folder-browser Library driven by one nav-state object, with breadcrumbs / back / tab-re-tap.
- `Source` / `RootFolder` / `FolderNode` data model; reachability index powering counts, All Songs, search, Go-to-Source.
- Settings **Sources manager** (main → source detail → add root → add source) + connection-state machine.
- Scoped recursive search; "Go to Source"; folder-aware "Playing from" labels.
- **Local + iCloud** sources via the system document picker + security-scoped bookmarks.
- **Google Drive** as a working OAuth source: consent, Keychain tokens, folder enumeration + metadata
  index, download-to-cache playback, lazy waveform/LUFS on first play.

### Non-goals (this round)
- **Dropbox / OneDrive** — the provider layer is built to accept them, but they are shown as
  "Coming soon" in Add Source and not implemented. (Confirmed scope decision.)
- **True Range-streaming-while-playing for Drive** — v1 downloads the file to the LRU cache and plays
  the local copy. Range streaming is a later optimization. (See §9.)
- Writing to user storage (we are strictly read-only), CarPlay-specific work, paid-team distribution.

### Supersession note (record in the spec, not silently)
`04-data-and-sources.md` originally said: *"Don't bundle vendor SDKs — expose Drive/Dropbox/OneDrive via
the system document picker as File Providers."* The v2.0 handoff **deliberately supersedes that for cloud
sources**: the folder-browser vision (mirror the provider tree, re-index in the background, scoped search
over local metadata, reliable streaming, "Go to Source" through the provider tree) is impossible with the
document-picker File-Provider approach, which only yields whatever files the user hand-picked. So Drive
uses **real OAuth + Drive REST v3**. Local/iCloud keep the picker + security-scoped bookmarks, where it
still fits. This divergence is intentional — note it where ADR-equivalents live for the app.

---

## 2. Current state (what exists today)

- **Persistence:** SwiftData. Two `@Model`s: `Track`, `Playlist`. Container built in `NanoMetersApp`.
- **`Track`:** `id:UUID`, `title/artist/album`, `sourceKind:String` (SourceKind rawValue), `bookmark:Data?`,
  `folderBookmark:Data?`, `displayPath:String`, `durationSec`, `format`, `sampleRate`, `hasEmbeddedArt`,
  `artworkData`, `bundledName:String?`, `artworkTintHex:String?`, `integratedLUFS:Double?`, `isLoved`,
  `dateAdded`, `waveformCacheKey:String`.
- **`Playlist`:** `id`, `name`, `subtitle`, `dateCreated`, `itemIDs:[UUID]` (explicit order), `coverOverrideTrackID`.
- **`SourceKind`:** enum `local/icloud/gdrive/onedrive/dropbox` + `label`. Only `.local` exercised.
- **`LibraryStore`:** stateless enum facade over `ModelContext` (fetch/append/move/remove).
- **Navigation:** hand-rolled. `RootView` `@State tab:Tab` (`library/playlists/search`); `NavigationStack`
  only inside Playlists. Library is a **flat** `@Query` list. Search is **flat, unscoped**.
- **Playback:** `PlayContext{kind,name}` (`.library/.search/.playlist`). `AudioEngine` (`@MainActor @Observable`)
  plays **local files only** via `AVAudioFile`; `resolveURL` = bundledName → security-scoped bookmark.
  No HTTP/Range. Live `LiveLUFSMeter` taps the mixer during playback (kept as-is).
- **Analysis:** `WaveformAnalyzer` (actor) requires a fully-decoded **local** `AVAudioFile`; FFI
  `nano_dsp_analyze` (mono→bins) + `nano_dsp_integrated_lufs` (L/R→LUFS) take complete PCM. `WaveformCache`
  keys by **SHA256 content hash** (size + first/last 64 KB) → `Caches/waveforms/{hash}.nmwave`.
- **Config:** XcodeGen `project.yml`, iOS 18, background-audio **on**, Keychain available via team
  provisioning. Bundle id **`com.willeasp.nanometers.ios`**, team `9GX3Z9282P` (free personal).
  **No URL schemes, no entitlements file, no networking, no OAuth.** Sim builds are credential-free
  (`CODE_SIGNING_ALLOWED[sdk=iphonesimulator*]=NO`).

---

## 3. Architecture — four layers

```
UI        LibraryScreen (folder browser) · SourcesSettings · scoped search header
          driven by LibraryNav (the handoff's libNav)
Domain    LibraryIndex (reachable set, counts, trackId→path)
          SourceProvider protocol · Source / RootFolder / FolderNode (@Model)
Providers LocalProvider · iCloudProvider · GoogleDriveProvider · MockProvider (tests)
Infra     OAuthClient (PKCE) · KeychainTokenStore · RemoteFileCache (LRU on disk)
```

### Key engineering decisions (and the alternative rejected)
1. **New models are SwiftData `@Model`s** — match `Track`/`Playlist`, get `@Query` reactivity so counts/
   reachability update live. *Rejected: runtime/Codable config (loses reactivity, needs manual change fan-out).*
2. **Drive playback/analysis = download-to-LRU-cache-then-play** — the cached file is a normal local URL,
   so `AVAudioFile`, `WaveformAnalyzer`, the content-hash cache, and the live meter all work **unchanged**.
   Handoff explicitly allows "LRU on-disk cache; full-decode for waveform/LUFS on first play." *Rejected for
   v1: Range-streaming-while-playing — needs an `AVAssetResourceLoaderDelegate` shim + a streaming decode
   feed the analyzer doesn't expose.*
3. **One `SourceProvider` protocol** for filesystem and cloud, so `LibraryNav` / search / index are
   source-agnostic. *Rejected: special-casing local vs cloud across the UI.*
4. **A single `@Observable LibraryIndex`** is the one place reachability/counts/path-resolution live,
   recomputed on connect/disconnect/add-root/remove-root and after enumeration. *Rejected: scattering this
   across views.*

---

## 4. Data model

New `@Model`s added to the container; `Track` gains reference fields (existing fields unchanged).

| Model | Fields |
|---|---|
| `Source` | `id:String` (stable `local`/`icloud`/`gdrive`) · `kind:String` · `label:String` · `tintHex:String` · `state:String` (§7 enum) · `authRef:String?` (Keychain account key) · `roots:[RootFolder]` (relationship) · `canonicalOrder:Int` |
| `RootFolder` | `id:UUID` · `sourceId:String` · `name:String` · `providerFolderId:String?` (cloud) **or** `bookmark:Data?` (local/iCloud) · `dateAdded:Date` |
| `FolderNode` (cache) | `id:String` (provider folder id, or a derived id for local) · `sourceId:String` · `name:String` · `parentId:String?` · `childFolderIds:[String]` · `trackIds:[UUID]` · `cursorOrEtag:String?` · `lastIndexed:Date?` |
| `Track` (+ new) | `sourceId:String?` · `providerFileId:String?` · `folderId:String?` (leaf FolderNode id). Existing `format`/`sampleRate`/`integratedLUFS` cover the handoff's `fmt`/`rate`/`lufs`. Keep `sourceKind` (denormalized) for back-compat + migration. |

- **Per-source tint** (handoff §01): Local `#B990F5`, iCloud `#5EC8C0`, Google Drive `#6FCF72`,
  Dropbox `#6AA6FF`, OneDrive `#8AB4F8`. Stored on `Source.tintHex`; `SourceKind` gains matching `tintHex`.
- **Path reconstruction:** a track's breadcrumb path is rebuilt by walking `FolderNode.parentId` up from
  `Track.folderId` to its root. "Go to Source" uses this to set `LibraryNav.folderIds`.
- **Canonical order** (`Source.canonicalOrder`): Local=0, iCloud=1, Google Drive=2, Dropbox=3, OneDrive=4 —
  the Library root never reshuffles by connection order.

### Persistence boundary
- Tokens are **never** in SwiftData — only a Keychain *account key* (`authRef`) is stored on `Source`.
- `FolderNode`/`Track` metadata are cached so All Songs, counts, and search are instant + offline.

---

## 5. Library navigation + folder browser

`@Observable LibraryNav { smart: SmartEntry?, sourceId: String?, folderIds: [String] }` — the **single**
state object that drives the whole Library tab (the handoff's `libNav`). It is the only thing breadcrumbs,
back, tab-re-tap, and "Go to Source" mutate.

```swift
enum SmartEntry { case allSongs }
@Observable final class LibraryNav {
    var smart: SmartEntry?
    var sourceId: String?
    var folderIds: [String] = []        // ordered path of FolderNode ids from a root down
    func reset()                         // → Library root
    func openAllSongs()
    func openSource(_ id: String)
    func openFolder(_ folderId: String)  // append
    func up()                            // pop one level (or → root at a source root)
    func jumpTo(crumbIndex: Int)         // breadcrumb tap
    func goToSource(_ track: Track, index: LibraryIndex)  // resolve path → set state
}
```

### Screens (render purely from `LibraryNav` + `LibraryIndex`)
- **Root** (`smart:nil, sourceId:nil, folderIds:[]`): "All Songs" smart row (accent tile, always first) +
  connected sources in canonical order. Each source row: tinted tile · label · `N folders · M tracks`
  (recursive) · status dot (green/amber/grey) · chevron. Header: large "Library" + search glyph (→ search)
  + gear (→ Settings sheet). Footer: quiet "Manage sources & root folders in Settings".
- **All Songs** (`smart:.allSongs`): flat reachable list (the old view), with the scoped-search affordance.
- **Source root / folder**: back chevron (→ parent name, or "Library" at a source root) · tappable
  breadcrumb · recursive **Play All** + **Shuffle** (when sub-folders exist) / **Play** (leaf) · **Folders**
  section ("Root Folders" at a source root, "Folders" deeper) then **Tracks** section (reuse `NMRow`) ·
  empty state "This folder is empty." · "Add or manage root folders…" footer at a source root (deep-links
  Settings).
- **Connected-but-noRoots** sources are **hidden** from the Library root.

### Integration with RootView
The Library tab content is hosted so back/breadcrumb/tab-re-tap work. `NMRow` is reused as-is for tracks.
Re-tapping the active Library tab → `LibraryNav.reset()` (standard iOS pop-to-root).

### Play scope nuance (handoff §3.2)
- Header **Play All** = whole subtree, depth-first, in folder order → queue.
- Tapping a **track row** = the visible sibling list of that folder → queue.

---

## 6. LibraryIndex — reachability, counts, paths

`@Observable LibraryIndex` derived over connected sources + their added roots + cached `FolderNode`s:
- `reachableTrackIds: Set<UUID>` — tracks under a **connected** source's **added** root. Powers All Songs +
  search + counts. Disconnect / remove-root drops tracks from reachable (but playlist refs persist).
- `counts[folderId] -> (folders, tracks)` recursive; `counts[sourceId]`, `counts[allSongs]`.
- `path[trackId] -> (sourceId, [folderId])` for "Go to Source" and result-row folder paths.
- Recompute triggers: connect, disconnect, addRoot, removeRoot, enumeration completes.

This is the single source for: source-row subtitles, All Songs list, search corpus, Go-to-Source nav,
"reachable" gating.

---

## 7. Search · Go-to-Source · Playing-from

### Scoped search (handoff §04)
- Search glyph in **every** folder/source/All-Songs header (shown only when scope has ≥1 track) toggles a
  field; glyph → ✕ to dismiss.
- Searches **current folder + all descendants** over the **local index** (no per-keystroke API). Case-
  insensitive substring on title + artist + album.
- Helper line: `N results in {scope}` (zero → "No tracks match …"). Result row = `NMRow` whose second line
  shows **artist · relative folder path**; All Songs shows the **full source path**.
- Tapping a result plays it (active list = the result set). Search auto-clears on any navigation.
- **Production:** cloud search runs over locally-indexed metadata cached at enumeration; re-index a root in
  the background when its listing changes (Drive `changes`/`nextPageToken`).

### Go to Source (handoff §5.2)
From any track `⋯` menu (playlist, queue, search) and the Now Playing folder button: resolve
`LibraryIndex.path[track.id]` → set `LibraryNav` → switch to Library tab → **accent-wash highlight** the row,
fading ~2.8 s. The `⋯` sub-label shows the resolved path (e.g. "iPhone / Field Recordings"). If the track's
source is **not connected**, the action is disabled and shows "{Source} · not connected" + offer reconnect.

### Playing-from (handoff §5.3)
Extend `PlayContext`:
```swift
struct PlayContext { var kind: String; var name: String; var nav: NavTarget? }
// NavTarget = enough to re-drive LibraryNav for the Now Playing folder button (sourceId + folderIds, or .allSongs / .playlist)
```
Label matrix: folder Play/Play-All → `PLAYING FROM {SOURCE} · {Folder}`; All Songs →
`PLAYING FROM LIBRARY · All Songs`; track-in-folder → folder name, queue = that folder's visible tracks;
playlist → `PLAYING FROM PLAYLIST · {name}` (unchanged). Adding to playlists stays fully source-agnostic.

---

## 8. Settings — Sources manager + state machine

A `NavigationStack` sheet with an internal stack (no nested modals). The existing waveform/analysis display
toggles stay as a separate group below "Library Sources".

- **Main:** "Library Sources" lists connected sources (tile · name · `N root folders · M tracks`) then
  **Add Source…**; then the existing Analysis group.
- **Source detail:** identity header (`Connected · N tracks`) · **Root Folders** list (each removable via
  trash) · **Add Root Folder…** · **Disconnect Source** (destructive).
- **Add Source:** "Available" = providers not yet connected, each a **Connect** pill (Drive only this round;
  Dropbox/OneDrive shown disabled "Coming soon"). Empty → "All available sources are connected."
- **Add Root Folder:** browse the provider's folders (Drive folder list; local = `UIDocumentPicker` folder
  mode) and pick one or more roots. Each pick appends and appears immediately in Library.

### Connection states (`Source.state`, drives the dot + copy)
`disconnected · authorizing · connected · noRoots · needsReauth · offline`
- green dot = connected & reachable; amber = needsReauth (tap re-runs OAuth); grey = offline (cached
  metadata browsable, playback of un-cached files disabled).
- A source can hold **any number of roots**, side by side at the source root; removing one never affects another.

---

## 9. Provider layer + OAuth + Google Drive

```swift
protocol SourceProvider {
    var sourceId: String { get }
    func pickRoots() async throws -> [RootFolder]                 // document picker / Drive folder browser
    func listChildren(_ folderId: String) async throws -> (folders: [FolderNode], tracks: [TrackMeta])
    func playableURL(for track: Track) async throws -> URL        // local: bookmark; cloud: download-to-cache
}
```

### Local + iCloud (no OAuth)
- `pickRoots` → `UIDocumentPickerViewController` in **folder** mode → security-scoped **bookmark** roots.
- `listChildren` → `FileManager` / `NSFileCoordinator` enumeration, filtered to audio UTIs (folders surface
  even if empty; files only if playable). iCloud may `startDownloadingUbiquitousItem` on first play.
- `playableURL` → resolve the bookmark (today's path), refresh on `bookmarkDataIsStale`.

### Google Drive (the Drive sub-project)
- **`OAuthClient`** — Authorization-Code + **PKCE (S256)**, `ASWebAuthenticationSession` (ephemeral, never
  `WKWebView`), `state` verification. Redirect = Google's **reversed-client-ID scheme**
  (`com.googleusercontent.apps.XXXX:/oauth`), registered in `project.yml → CFBundleURLTypes`.
- **`KeychainTokenStore`** — `kSecClassGenericPassword`, per-provider account, `kSecAttrAccessibleAfterFirstUnlock`.
  Proactive refresh near `expires_in` + on `401`; refreshes serialized. Disconnect = best-effort revoke +
  delete creds + drop cached `FolderNode`/metadata.
- **`GoogleDriveProvider`** — Drive REST v3:
  - `pickRoots` → browse folders (`files.list q="'{id}' in parents and mimeType='application/vnd.google-apps.folder'"`).
  - `listChildren` → `files.list q="'{id}' in parents"` (folders + audio mime types), paginated; cache
    `nextPageToken`/changes token on the `FolderNode`. Metadata (title/artist/album/duration/format) indexed
    at enumeration into `FolderNode`/`Track`.
  - `playableURL` → `files.get?alt=media` with HTTP **Range** into **`RemoteFileCache`** (LRU on disk),
    returns the local cached file URL. Scope `drive.readonly`.
- **`RemoteFileCache`** — LRU on-disk cache of downloaded audio under `Caches/remote/`, keyed by
  `(sourceId, providerFileId)`; eviction by size budget; survives relaunch.

### AudioEngine changes (minimal, downstream untouched)
- Add an async **`prepare(track) -> URL?`**: local/bundled resolve as today; remote → if not cached, set a
  `downloading` transport state, await `RemoteFileCache` fill (Range GET), then return the local URL.
- `play(...)` becomes able to await `prepare` before `loadAndStart(localURL)`. **`AVAudioFile`, waveform,
  LUFS, scrubbing, live meter — all unchanged**, because by the time they run, the file is a local URL.
- Waveform/LUFS: the existing `WaveformAnalyzer` runs on the cached local file on first play; content-hash
  cache then makes it instant. (Same copy of a song under Local + Drive shares one cache entry by hash.)

---

## 10. Project config + Google Cloud setup

### App side (I do)
- Add `CFBundleURLTypes` for the Google reversed-client-ID scheme to `project.yml → info.properties`.
- Add an explicit `.entitlements` only if provisioning needs it (Keychain works under the team prefix
  already; iCloud Drive enumeration via picker + bookmarks needs no iCloud-container entitlement).
- Keep bundle id `com.willeasp.nanometers.ios` and team `9GX3Z9282P`. Background-audio already on.

### Google Cloud side (you do — I provide the exact click-path)
1. Create a Google Cloud project.
2. OAuth **consent screen**: External, app name, your email; add **yourself as a Test user** (keeps it in
   "testing" so no verification needed); scope `.../auth/drive.readonly`.
3. Create an **iOS OAuth client** with bundle id `com.willeasp.nanometers.ios`.
4. Hand me the **client ID** (no client secret — PKCE). I wire the client ID + reversed-client-ID scheme in.

Free Apple team is sufficient for OAuth (custom URL scheme + Keychain both work without a paid account).

---

## 11. Migration

On first launch of the new build: seed a `local` **Source** (canonicalOrder 0, "On My iPhone") with one
synthetic root folder; attach existing imported `Track`s + the two bundled demos to it (flat, under that
root) so they stay **reachable**. Update `DemoSeed` + add a one-shot, idempotent migration. Existing
per-file imports keep working; new local roots are added by picking folders.

---

## 12. Build phases (foundation → Drive)

1. **Models + migration + LibraryIndex** — unit-tested; app still renders the flat list.
2. **Folder-browser Library + LibraryNav** — Local/iCloud only; XCUITest drill/back/breadcrumb/tab-re-tap.
3. **Scoped search + Go-to-Source + Playing-from labels.**
4. **Settings Sources manager** — connect Local/iCloud, add/remove roots, status dots, state machine.
5. **OAuth + GoogleDriveProvider + RemoteFileCache + download-to-cache playback** — the Drive sub-project.
6. **Polish + one manual on-device Google sign-in run.**

Each phase ends green (build + tests) and is independently meaningful.

---

## 13. Testing strategy

- **Unit:** PKCE challenge/verifier + token lifecycle (refresh, 401-retry, serialize); Drive `files.list`
  JSON → `FolderNode`/`TrackMeta` parsing; `LibraryIndex` reachability/counts/path; `LibraryNav` transitions
  (open/up/jumpTo/goToSource); migration idempotency; `RemoteFileCache` LRU eviction.
- **XCUITest:** folder browser (drill in/out, breadcrumb jump, tab-re-tap, empty state), scoped search,
  Go-to-Source highlight, Settings Sources manager (add/remove root, disconnect) — all against a
  **`MockProvider`** with a fixed fake tree (no network).
- **Manual (once, on device):** the live Google consent screen → tokens in Keychain → a Drive folder
  enumerates → a Drive track downloads, plays, and shows waveform/LUFS. (Consent can't run headless.)
- Reuse the existing self-test hooks (`-autoplay`, `-expand`) and the `AudioEngine.outputLevel` mixer tap
  for audio assertions.

---

## 14. Edge cases & acceptance (from handoff §10)

### Edge cases
- Remove the root you're inside → bounce up to the source root.
- Disconnect the source you're inside → bounce to Library root.
- Folder moved/deleted on provider → error placeholder in that folder; offer "remove root / re-pick".
- Token revoked mid-session → `needsReauth`; cached listings stay browsable, un-cached playback blocked.
- Same file under two roots → appears in both; Go-to-Source resolves to the indexed one.
- Playlist track whose source was removed → row marked unavailable; Go-to-Source disabled.
- Connected, zero roots → source hidden from Library; detail nudges to add a root.
- Empty folder → explicit empty state, no phantom Play button.

### Acceptance criteria
- [ ] Library root lists only connected sources + All Songs, in canonical order.
- [ ] A source can hold multiple roots; each browses its real sub-tree.
- [ ] Breadcrumbs jump to any ancestor; back pops one level; Library re-tap → root.
- [ ] Header search is scoped & recursive; results show folder paths; clears on nav.
- [ ] Play All plays the whole subtree; track tap plays the visible list.
- [ ] Go to Source navigates & highlights from any track context; disabled when disconnected.
- [ ] Connecting Google Drive runs OAuth 2.0 + PKCE via `ASWebAuthenticationSession`; tokens in Keychain.
- [ ] Disconnect revokes & clears creds; playlists keep refs as unavailable.
- [ ] All Songs, counts, and search read only reachable tracks and update live on connect/disconnect/add/remove-root.
- [ ] A Google Drive track downloads to the LRU cache, plays, and renders waveform + LUFS on first play.
