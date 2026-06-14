# Library & Sources — Phase 3: Scoped Search + Go-to-Source + Playing-from

> **For agentic workers:** REQUIRED SUB-SKILL: subagent-driven-development / executing-plans. Steps use `- [ ]`.

**Goal:** A scoped, recursive search in every folder/source/All-Songs header (searches the current scope's subtree over the local index; result rows show the folder path). "Go to Source" from any track's `⋯` menu and from Now Playing navigates the Library to the file's folder and flashes the row. Folder-aware "Playing from" labels are finished and the Now Playing folder button is wired.

**Architecture:** The search + path logic is a **pure resolver** (`LibraryBrowse.search(...)`, `LibraryBrowse.relativePath(...)`) over `BrowseContent.playAll` (already the recursive scope track set) + `LibraryIndex.trackPath` — unit-tested. Go-to-Source is driven by a small signal on `LibraryNav` (`highlightTrackId` + a `switchToLibraryToken` RootView observes to flip the tab). `TrackContextSheet` (used from playlist/queue/search/Now Playing) and the Now Playing folder button call one shared `goToSource(track)` path. No new persistence.

**Tech Stack:** SwiftUI, SwiftData, XCTest + XCUITest. Sim: **iPhone 16 Pro (Nano)** `id=28DD8D81-668A-4887-98E8-BFE3CC625596` (never the 17).

**Spec:** `…/specs/2026-06-14-…-design.md` §7 (search/Go-to-Source/Playing-from); handoff §04 (scoped search), §5.2 (Go to Source), §5.3 (Playing from).

**Depends on Phase 2:** `LibraryNav`, `LibraryBrowse.content`/`BrowseContent` (`.playAll` = recursive scope tracks), `LibraryIndex.trackPath`/`reachableTrackIds`, `LibraryStore`, `SourceKind.short`. `PlayContext` already carries folder labels from Phase 2.

---

## Conventions (every task)
- Unit: `-only-testing:NanoMetersTests`; UI: `-only-testing:NanoMetersUITests`. Nano sim id above (never 17).
- New file → `cd apps/nano-ios && xcodegen generate`; **never `git add` the gitignored `NanoMeters.xcodeproj`**.
- Commit per task, Conventional Commits, end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Match existing style (Theme tokens, `NMRow`, `Color(hex:String)`).

---

## File Structure
**Create:** `Tests/LibrarySearchTests.swift`, `UITests/SearchAndGoToSourceUITests.swift`.
**Modify:**
- `Sources/Model/LibraryBrowse.swift` — `search(...)` + `relativePath(...)`.
- `Sources/Model/LibraryNav.swift` — `highlightTrackId`, `switchToLibraryToken`, `goToSource(track:index:ctx:)`.
- `Sources/Screens/LibraryScreen.swift` — search field + results; row highlight wash.
- `Sources/Screens/TrackContextSheet.swift` — "Go to Source" action.
- `Sources/Screens/NowPlayingScreen.swift` — enable the bottom-rail folder button.
- `Sources/RootView.swift` — observe `switchToLibraryToken` → `tab = .library`.

---

## Task 1: Scoped-search resolver + relative path

**Files:** Modify `Sources/Model/LibraryBrowse.swift`; create `Tests/LibrarySearchTests.swift`.

- [ ] **Step 1: Failing tests** — `Tests/LibrarySearchTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibrarySearchTests: XCTestCase {
    /// gdrive root "mine" → House[Caldera by Oso], DnB[Strata by Oso]; All reachable.
    private func fixture() throws -> (ModelContext, LibraryIndex) {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "mine"))
        func t(_ title: String, _ artist: String, _ folder: String) -> UUID {
            let tr = Track(title: title, artist: artist, album: ""); tr.sourceId = "gdrive"; tr.folderId = folder
            ctx.insert(tr); return tr.id
        }
        let c = t("Caldera", "Oso", "house"); let s = t("Strata", "Oso", "dnb")
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "My Productions", parentId: nil, childFolderIds: ["house","dnb"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [c]))
        ctx.insert(FolderNode(id: "dnb", sourceId: "gdrive", name: "Drum & Bass", parentId: "mine", trackIds: [s]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        return (ctx, idx)
    }

    func test_search_recursesScope_caseInsensitive_titleArtist() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive")              // scope = whole Drive
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        let hits = LibraryBrowse.search(scope, query: "calder", nav: n, index: idx, ctx: ctx)
        XCTAssertEqual(hits.map(\.track.title), ["Caldera"])
        XCTAssertEqual(hits.first?.pathLabel, "My Productions / House")   // folder path under source
    }

    func test_search_inLeafFolder_onlyThatSubtree() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine"); n.openFolder("dnb")
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        XCTAssertEqual(LibraryBrowse.search(scope, query: "oso", nav: n, index: idx, ctx: ctx).map(\.track.title), ["Strata"])
    }

    func test_search_allSongs_pathHasSourceShortPrefix() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openAllSongs()
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        let hits = LibraryBrowse.search(scope, query: "strata", nav: n, index: idx, ctx: ctx)
        XCTAssertEqual(hits.first?.pathLabel, "Drive / My Productions / Drum & Bass")  // §04: full source path
    }

    func test_search_emptyQuery_noHits() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openAllSongs()
        let scope = LibraryBrowse.content(for: n, index: idx, ctx: ctx).playAll
        XCTAssertTrue(LibraryBrowse.search(scope, query: "  ", nav: n, index: idx, ctx: ctx).isEmpty)
    }
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — add to `LibraryBrowse` (and a `SearchHit` type):
```swift
struct SearchHit: Equatable { var track: Track; var pathLabel: String
    static func == (a: SearchHit, b: SearchHit) -> Bool { a.track.id == b.track.id && a.pathLabel == b.pathLabel } }

extension LibraryBrowse {
    /// Filter the already-recursive `scope` tracks by `query` (case-insensitive over title/artist/album),
    /// each hit annotated with its folder path. Empty/whitespace query → no hits (search is opt-in).
    @MainActor
    static func search(_ scope: [Track], query: String, nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> [SearchHit] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return [] }
        return scope.filter {
            $0.title.lowercased().contains(q) || $0.artist.lowercased().contains(q) || $0.album.lowercased().contains(q)
        }.map { SearchHit(track: $0, pathLabel: relativePath(for: $0, allSongs: nav.smart == .allSongs, index: index, ctx: ctx)) }
    }

    /// Folder path for a hit. Under a source scope: "Folder / Sub" (no source name). Under All Songs:
    /// "SourceShort / Folder / Sub" (handoff §04). Names resolved from the cached FolderNodes (offline-safe).
    @MainActor
    static func relativePath(for track: Track, allSongs: Bool, index: LibraryIndex, ctx: ModelContext) -> String {
        guard let p = index.trackPath[track.id] else { return "" }
        let names = p.folderIds.compactMap { (try? LibraryStore.folderNode(id: $0, ctx))?.name }
        if allSongs {
            let short = (try? LibraryStore.source(id: p.sourceId, ctx)).flatMap { SourceKind(rawValue: $0.kind)?.short } ?? ""
            return ([short] + names).filter { !$0.isEmpty }.joined(separator: " / ")
        }
        return names.joined(separator: " / ")
    }
}
```
> `trackPath.folderIds` is root→leaf, so the leaf folder is included (e.g. ["mine","house"] → "My Productions / House"). That matches the handoff mockup ("My Productions / House").

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): scoped recursive search resolver + folder-path labels`.

---

## Task 2: LibraryNav — highlight + Go-to-Source signal

**Files:** Modify `Sources/Model/LibraryNav.swift`; extend `Tests/LibraryNavTests.swift`.

- [ ] **Step 1: Failing tests** — append to `LibraryNavTests`:
```swift
    func test_goToSource_resolvesPath_setsHighlight_andRequestsLibrary() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "P", providerFolderId: "mine"))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"
        ctx.insert(tr)
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "P", parentId: nil, childFolderIds: ["house"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [tr.id]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        let n = LibraryNav()
        let before = n.switchToLibraryToken
        let ok = n.goToSource(track: tr, index: idx, ctx: ctx)
        XCTAssertTrue(ok)
        XCTAssertEqual(n.sourceId, "gdrive"); XCTAssertEqual(n.folderIds, ["mine", "house"])
        XCTAssertEqual(n.highlightTrackId, tr.id)
        XCTAssertGreaterThan(n.switchToLibraryToken, before)
    }
    func test_goToSource_disconnectedSource_returnsFalse_noNav() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .disconnected))
        let tr = Track(title: "X", artist: "", album: ""); tr.sourceId = "gdrive"; tr.folderId = "house"; ctx.insert(tr)
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        let n = LibraryNav()
        XCTAssertFalse(n.goToSource(track: tr, index: idx, ctx: ctx))
        XCTAssertNil(n.sourceId)
    }
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — add to `LibraryNav`:
```swift
    /// The row to flash after a Go-to-Source jump (handoff §5.2). LibraryScreen clears it after ~2.8 s.
    var highlightTrackId: UUID?
    /// Bumped to ask RootView to switch to the Library tab (Go-to-Source from a sheet/other tab).
    private(set) var switchToLibraryToken = 0

    /// Navigate to the folder holding `track` and flash it. Returns false (no-op) when the track's source
    /// is missing or disconnected (handoff §5.2 "{Source} · not connected" → action disabled).
    @MainActor
    func goToSource(track: Track, index: LibraryIndex, ctx: ModelContext) -> Bool {
        guard let p = index.trackPath[track.id],
              let source = try? LibraryStore.source(id: p.sourceId, ctx),
              SourceState(rawValue: source.state) != .disconnected else { return false }
        smart = nil; sourceId = p.sourceId; folderIds = p.folderIds
        highlightTrackId = track.id
        switchToLibraryToken += 1
        return true
    }
```

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): LibraryNav.goToSource — path resolve + highlight + tab signal`.

---

## Task 3: LibraryScreen — scoped search UI

**Files:** Modify `Sources/Screens/LibraryScreen.swift`.

- [ ] **Step 1:** Add `@State private var searchActive = false`, `@State private var searchText = ""`. In the header (folder/source/All-Songs levels), add a search glyph button (`GlassRoundButton("magnifyingglass")`) shown only when `content.playAll` is non-empty; tapping toggles `searchActive`; when active the glyph becomes an `xmark` (`.accessibilityIdentifier("searchToggle")`).
- [ ] **Step 2:** When `searchActive`, render a search `TextField` (`.accessibilityIdentifier("scopedSearchField")`, placeholder `"Search in \(content.title)"`) styled like `SearchScreen`'s field. Below it a helper line: `"\(hits.count) results in \(content.title)"` (mono, text3); zero → `"No tracks match \"\(searchText)\""`. Compute `let hits = LibraryBrowse.search(content.playAll, query: searchText, nav: nav, index: index, ctx: ctx)`.
- [ ] **Step 3:** When `searchActive` && `!searchText.isEmpty`, replace the Folders/Tracks sections with the hit list: `ForEach(hits, id: \.track.id)` → `NMRow(track:)` whose context play is `engine.play(hit.track, in: hits.map(\.track), context: .search)`, and show `hit.pathLabel` as the row's second line. Since `NMRow` shows artist·album, add a small variant or overlay: simplest — render a custom result row here (artwork + title + `"\(track.artist) · \(hit.pathLabel)"` + LUFS) rather than `NMRow`, so the path shows. Keep it visually consistent with `NMRow`.
- [ ] **Step 4: Auto-clear on nav** — when `nav.sourceId`/`nav.folderIds`/`nav.smart` change (any navigation), reset `searchActive = false; searchText = ""`. Implement via `.onChange(of: navKey)` where `navKey` is a string of the nav state (e.g. `"\(nav.smart.debugDescription)|\(nav.sourceId ?? "")|\(nav.folderIds.joined(separator: ">"))"`).
- [ ] **Step 5: Build + run unit suite** — `BUILD SUCCEEDED`, unit green. Commit: `feat(ios): scoped search UI in the Library folder browser`.

> Search lives only at folder/source/All-Songs levels, NOT the Library root (root has no `playAll`). Keep the existing top-level search glass button (→ Search tab) at the root.

---

## Task 4: LibraryScreen — Go-to-Source highlight wash

**Files:** Modify `Sources/Screens/LibraryScreen.swift`.

- [ ] **Step 1:** When rendering track rows (folder + All-Songs levels), wrap each row in a background that is `Theme.accent.opacity(0.18)` when `nav.highlightTrackId == track.id`, else clear, animated.
- [ ] **Step 2:** When `nav.highlightTrackId` becomes non-nil, scroll to it (wrap the track list in a `ScrollViewReader`, `proxy.scrollTo(track.id, anchor: .center)`), then clear it after ~2.8 s: `.task(id: nav.highlightTrackId) { if nav.highlightTrackId != nil { try? await Task.sleep(for: .seconds(2.8)); nav.highlightTrackId = nil } }`. Give rows `.id(track.id)`.
- [ ] **Step 3: Build + unit suite green.** Commit: `feat(ios): Go-to-Source accent-wash highlight + scroll-to-row`.

---

## Task 5: TrackContextSheet — "Go to Source" action

**Files:** Modify `Sources/Screens/TrackContextSheet.swift`.

- [ ] **Step 1:** Add `@Environment(LibraryNav.self) private var nav` and `@Environment(LibraryIndex.self) private var index` and `@Environment(\.modelContext) private var ctx` (sheets inherit the environment injected by RootView). Compute `let path = LibraryBrowse.relativePath(for: track, allSongs: true, index: index, ctx: ctx)` and `let connected = (try? LibraryStore.source(id: track.sourceId ?? "", ctx)).map { SourceState(rawValue: $0.state) != .disconnected } ?? false`.
- [ ] **Step 2:** Add a "Go to Source" row in the actions section with the resolved `path` as a sub-label (e.g. "iPhone / Field Recordings"), icon `folder`. When `connected` && path non-empty → `if nav.goToSource(track: track, index: index, ctx: ctx) { dismiss() }`. When not connected → render it disabled with sub-label `"\(sourceLabel) · not connected"` (handoff §5.2), `.disabled(true)`. `.accessibilityIdentifier("goToSource")`.
- [ ] **Step 3: Build + unit suite green.** Commit: `feat(ios): Go to Source action in the track context menu`.

> The sheet is presented from LibraryScreen/PlaylistDetail/QueueSheet/Search/Now Playing — all inherit RootView's `.environment(libNav)`/`.environment(libIndex)`, so this one action covers every context (§5.2).

---

## Task 6: NowPlaying folder button + RootView tab switch

**Files:** Modify `Sources/Screens/NowPlayingScreen.swift`, `Sources/RootView.swift`.

- [ ] **Step 1: NowPlaying** — the `bottomRail` `folder` button is currently disabled ("v2"). Wire it: `@Environment(LibraryNav.self) private var nav`, `@Environment(LibraryIndex.self) private var index`, `@Environment(\.modelContext) private var ctx`. On tap, `if let t = engine.current, nav.goToSource(track: t, index: index, ctx: ctx) { onClose() }`. Enable it (full opacity) only when `engine.current` has a resolvable, connected path; else keep it dimmed/disabled. `.accessibilityIdentifier("npGoToSource")`.
- [ ] **Step 2: RootView** — observe the signal: `.onChange(of: libNav.switchToLibraryToken) { tab = .library }` so Go-to-Source from a sheet/Now Playing flips to the Library tab (which is already navigated by `goToSource`). Now Playing's `onClose` dismisses the cover; the tab switch lands on the browser at the file's folder with the row flashing.
- [ ] **Step 3: Build + unit suite green.** Commit: `feat(ios): wire Now Playing folder button to Go to Source`.

---

## Task 7: XCUITest — scoped search + Go-to-Source

**Files:** Create `UITests/SearchAndGoToSourceUITests.swift`.

- [ ] **Step 1:** Read `UITests/LibraryBrowserUITests.swift` for the launch + query idioms. Write:
  - `test_scopedSearch_filtersWithinFolder`: launch → tap `sourceRow-local` → tap `folderRow-On My iPhone` → tap `searchToggle` → type "Mercy" in `scopedSearchField` → assert `Mercy` row shows and `Biljam` does NOT.
  - `test_goToSource_fromContextMenu_navigatesAndHighlights`: launch → All Songs → open a track's `⋯` (`rowEllipsis`) → tap `goToSource` → assert the Library shows the folder (`breadcrumb` exists) and the track title is visible. (Highlight fade is timing-based; assert the row is present, not the wash.)
- [ ] **Step 2:** Run `-only-testing:NanoMetersUITests/SearchAndGoToSourceUITests` on the Nano sim; iterate queries until green. Then run the full UI bundle to confirm no regressions.
- [ ] **Step 3: Commit** — `test(ios): XCUITest for scoped search + Go-to-Source`.

---

## Phase 3 acceptance
- [ ] Scoped search filters the current subtree (recursive), case-insensitive, with folder-path labels; All Songs shows full source path; clears on nav. (unit + XCUITest)
- [ ] Go to Source from the `⋯` menu (any context) and the Now Playing folder button navigates the Library to the file's folder, flips the tab, and flashes the row; disabled when the source is disconnected.
- [ ] Playing-from labels read `PLAYING FROM {SOURCE} · {Folder}` / `LIBRARY · All Songs` / `PLAYLIST · {name}`.
- [ ] Full unit + UI suites green on the Nano sim.

**Next:** Phase 4 — Settings Sources manager + connection-state machine (its own plan).
