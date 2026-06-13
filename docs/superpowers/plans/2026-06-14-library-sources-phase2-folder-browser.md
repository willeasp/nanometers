# Library & Sources — Phase 2: LibraryNav + Folder-Browser UI

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Turn the flat Library tab into a folder browser driven by one nav-state object (`LibraryNav`). Root shows "All Songs" + connected sources; drilling shows sub-folders + tracks with a tappable breadcrumb, back, recursive Play All / Shuffle, and empty states. Tab re-tap pops to the Library root. Reads everything from `LibraryIndex` (counts/reachable) + `LibraryStore` (folders/tracks). Local source only (the migrated "On My iPhone"); cloud comes later.

**Architecture:** The hard logic is extracted into a **pure, unit-testable resolver** — `LibraryBrowse.content(for:index:ctx:)` returns a `BrowseContent` value type (level, title, breadcrumbs, sources, folders, tracks, recursive play-all list, play context). The SwiftUI views are thin renderers of `BrowseContent`. `LibraryNav` and a shared `LibraryIndex` live in `RootView` and are injected via `.environment`, so Go-to-Source (Phase 3) from any tab can re-drive them. No SwiftData relationships — all reads go through the `LibraryStore` helpers from Phase 1.

**Tech Stack:** SwiftUI, SwiftData, XCTest + XCUITest. Sim: **iPhone 16 Pro (Nano)** `id=28DD8D81-668A-4887-98E8-BFE3CC625596` (never the 17).

**Spec:** `…/specs/2026-06-14-library-and-sources-design.md` §5 (navigation + folder browser), §6 (LibraryIndex), §3.1/§3.2 mockups in the handoff HTML.

**Depends on Phase 1:** `LibraryIndex` (`reachableTrackIds`, `sourceCounts`, `folderCounts`, `trackPath`), `LibraryStore.allSources/source(id:)/rootFolders(of:)/folderNode(id:)/childFolders(of:)/tracksInFolder(id:)`, `Source.state`/`canonicalOrder`, `SourceKind.tintHex/short`, `SourcesMigration.localRootNodeId`.

---

## Conventions (every task)
- Unit tests: `xcodebuild test … -only-testing:NanoMetersTests`. UI tests: `-only-testing:NanoMetersUITests`. Full: drop `-only-testing`.
- Run on the Nano sim id above. After adding a NEW file run `cd apps/nano-ios && xcodegen generate`; **never `git add` the gitignored `NanoMeters.xcodeproj`**.
- Commit per task, Conventional Commits, end with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.
- Match existing component style (Theme tokens, `NMRow`, `GlassRoundButton`, `Color(hex:String)`). Views read `Theme.*` — never hard-code hexes.

---

## File Structure
**Create:**
- `Sources/Model/LibraryNav.swift` — `@Observable` nav state + mutators.
- `Sources/Model/LibraryBrowse.swift` — `BrowseContent` value type + pure resolver.
- `Sources/Components/SourceRow.swift` — a source row (tinted tile, label, `N folders · M tracks`, status dot, chevron).
- `Sources/Components/FolderRow.swift` — a folder row (tinted folder glyph, name, recursive count, chevron).
- `Sources/Components/LibraryBreadcrumb.swift` — back chevron + tappable mono breadcrumb.
- `Tests/LibraryNavTests.swift`, `Tests/LibraryBrowseTests.swift`.
- `UITests/LibraryBrowserUITests.swift`.
**Modify:**
- `Sources/Screens/LibraryScreen.swift` — render `BrowseContent` for root / All Songs / folder levels.
- `Sources/RootView.swift` — own + inject `LibraryNav` + `LibraryIndex`; rebuild index; tab re-tap → reset.
- `Sources/Components/GlassTabBar.swift` — add `onReselect` so re-tapping the active tab pops to root.

---

## Task 1: LibraryNav — nav state + transitions

**Files:** Create `Sources/Model/LibraryNav.swift`, `Tests/LibraryNavTests.swift`.

- [ ] **Step 1: Failing tests** — `Tests/LibraryNavTests.swift`:
```swift
import XCTest
@testable import NanoMeters

@MainActor
final class LibraryNavTests: XCTestCase {
    func test_root_isDefault() {
        let n = LibraryNav()
        XCTAssertNil(n.smart); XCTAssertNil(n.sourceId); XCTAssertEqual(n.folderIds, [])
        XCTAssertTrue(n.isRoot)
    }
    func test_openSource_thenFolders_thenUp() {
        let n = LibraryNav()
        n.openSource("gdrive")
        XCTAssertEqual(n.sourceId, "gdrive"); XCTAssertEqual(n.folderIds, []); XCTAssertFalse(n.isRoot)
        n.openFolder("mine"); n.openFolder("house")
        XCTAssertEqual(n.folderIds, ["mine", "house"])
        n.up(); XCTAssertEqual(n.folderIds, ["mine"])
        n.up(); XCTAssertEqual(n.folderIds, [])           // at source root
        n.up(); XCTAssertTrue(n.isRoot)                   // pops to Library root
    }
    func test_jumpTo_breadcrumbAncestor() {
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine"); n.openFolder("house")
        n.jumpTo(folderDepth: 1)                          // keep first folder only
        XCTAssertEqual(n.folderIds, ["mine"])
        n.jumpTo(folderDepth: 0)                          // source root
        XCTAssertEqual(n.folderIds, [])
    }
    func test_openAllSongs_andReset() {
        let n = LibraryNav(); n.openSource("gdrive")
        n.openAllSongs()
        XCTAssertEqual(n.smart, .allSongs); XCTAssertNil(n.sourceId)
        n.reset(); XCTAssertTrue(n.isRoot); XCTAssertNil(n.smart)
    }
    func test_goToSource_setsSourceAndPath() {
        let n = LibraryNav()
        n.goToSource(sourceId: "gdrive", folderIds: ["mine", "house"])
        XCTAssertEqual(n.sourceId, "gdrive"); XCTAssertEqual(n.folderIds, ["mine", "house"])
        XCTAssertNil(n.smart)
    }
}
```

- [ ] **Step 2: Run — fails** (`cannot find 'LibraryNav'`).

- [ ] **Step 3: Implement** — `Sources/Model/LibraryNav.swift`:
```swift
import Foundation
import Observation

enum SmartEntry: Equatable { case allSongs }

/// The single nav-state object that drives the whole Library tab (handoff §02 `libNav`). Breadcrumbs,
/// back, tab re-tap, and Go-to-Source are just different ways of writing this. Owned by RootView and
/// injected, so any track context (playlist/queue/search/Now Playing) can re-drive it.
@MainActor
@Observable
final class LibraryNav {
    var smart: SmartEntry?
    var sourceId: String?
    var folderIds: [String] = []

    var isRoot: Bool { smart == nil && sourceId == nil }

    func reset() { smart = nil; sourceId = nil; folderIds = [] }
    func openAllSongs() { smart = .allSongs; sourceId = nil; folderIds = [] }
    func openSource(_ id: String) { smart = nil; sourceId = id; folderIds = [] }
    func openFolder(_ folderId: String) { folderIds.append(folderId) }

    /// Pop one level: a folder → its parent; at a source root → Library root.
    func up() {
        if !folderIds.isEmpty { folderIds.removeLast() }
        else { reset() }
    }

    /// Breadcrumb tap: keep the first `folderDepth` folder ids (0 = source root).
    func jumpTo(folderDepth: Int) {
        guard folderDepth >= 0, folderDepth < folderIds.count else {
            if folderDepth <= 0 { folderIds = [] }
            return
        }
        folderIds = Array(folderIds.prefix(folderDepth))
    }

    /// Go to Source (handoff §5.2): set the source + full path directly.
    func goToSource(sourceId: String, folderIds: [String]) {
        self.smart = nil; self.sourceId = sourceId; self.folderIds = folderIds
    }
}
```

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): LibraryNav — single nav-state object for the Library tab`.

---

## Task 2: BrowseContent + resolver — ROOT level

**Files:** Create `Sources/Model/LibraryBrowse.swift`, `Tests/LibraryBrowseTests.swift`.

The resolver turns `(LibraryNav, LibraryIndex, ModelContext)` into a render model. This task handles the **root** level (All Songs entry + connected sources).

- [ ] **Step 1: Failing test** — `Tests/LibraryBrowseTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibraryBrowseTests: XCTestCase {
    /// gdrive(connected, root "mine"→house[2]) + local(connected, root "local-root"[1]) + dropbox(disconnected)
    private func fixture() throws -> (ModelContext, LibraryIndex) {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "local", kind: .local, state: .connected))
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(Source(id: "dropbox", kind: .dropbox, state: .disconnected))
        ctx.insert(RootFolder(sourceId: "local", name: "On My iPhone"))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "mine"))
        func t(_ title: String, _ folder: String) -> UUID {
            let tr = Track(title: title, artist: "", album: ""); tr.sourceId = folder == "local-root" ? "local" : "gdrive"; tr.folderId = folder
            ctx.insert(tr); return tr.id
        }
        let l1 = t("local1", "local-root")
        let h1 = t("h1", "house"); let h2 = t("h2", "house")
        ctx.insert(FolderNode(id: "local-root", sourceId: "local", name: "On My iPhone", parentId: nil, trackIds: [l1]))
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "My Productions", parentId: nil, childFolderIds: ["house"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [h1, h2]))
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        return (ctx, idx)
    }

    func test_root_listsAllSongs_andConnectedSources_inCanonicalOrder_excludingDisconnected() throws {
        let (ctx, idx) = try fixture()
        let c = LibraryBrowse.content(for: LibraryNav(), index: idx, ctx: ctx)
        XCTAssertEqual(c.level, .root)
        XCTAssertEqual(c.allSongsCount, 3)                      // reachable only (dropbox excluded)
        XCTAssertEqual(c.sources.map(\.id), ["local", "gdrive"]) // canonical order, dropbox hidden
    }
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — `Sources/Model/LibraryBrowse.swift`:
```swift
import Foundation
import SwiftData

/// A pure, render-ready snapshot of the Library tab for the current `LibraryNav` (handoff §03). Views
/// render this; all SwiftData reads happen here so the logic is unit-testable.
struct BrowseContent {
    enum Level { case root, allSongs, folder }
    struct Crumb: Equatable { var label: String; var folderDepth: Int }   // folderDepth for LibraryNav.jumpTo

    var level: Level
    var title: String = ""
    var crumbs: [Crumb] = []
    var sources: [Source] = []          // root level
    var allSongsCount: Int = 0          // root level
    var folders: [FolderNode] = []      // folder level (sub-folders)
    var tracks: [Track] = []            // folder/allSongs level (direct tracks)
    var playAll: [Track] = []           // recursive, depth-first, for the header Play All
    var sourceTint: String = "#9AA1B0"
    var showsPlayAll: Bool { !playAll.isEmpty }
}

enum LibraryBrowse {
    @MainActor
    static func content(for nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        if nav.smart == .allSongs { return allSongsContent(index: index, ctx: ctx) }
        if let sourceId = nav.sourceId { return folderContent(sourceId: sourceId, nav: nav, index: index, ctx: ctx) }
        return rootContent(index: index, ctx: ctx)
    }

    @MainActor
    private static func rootContent(index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        let all = (try? LibraryStore.allSources(ctx)) ?? []
        // Show non-disconnected sources that have ≥1 root → hides `disconnected` and connected-zero-roots (§8).
        let visible = all.filter {
            SourceState(rawValue: $0.state) != .disconnected
                && !((try? LibraryStore.rootFolders(of: $0.id, ctx))?.isEmpty ?? true)
        }
        var c = BrowseContent(level: .root, title: "Library")
        c.sources = visible
        c.allSongsCount = index.reachableTrackIds.count
        return c
    }
    // folderContent + allSongsContent added in Tasks 3 & 4.
}
```
> Note: the `rootContent` filter hides sources with **no roots** (handoff: connected-zero-roots is hidden). `disconnected` is also hidden. Keep `offline`/`needsReauth` visible (they're browsable from cache).

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): BrowseContent + root-level resolver (sources + All Songs)`.

---

## Task 3: Resolver — FOLDER level (sub-folders, tracks, breadcrumb, recursive Play All)

**Files:** Modify `Sources/Model/LibraryBrowse.swift`; extend `Tests/LibraryBrowseTests.swift`.

- [ ] **Step 1: Failing tests** — append:
```swift
    func test_sourceRoot_showsRootFolders_andBreadcrumb() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive")
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.level, .folder)
        XCTAssertEqual(c.title, "My Productions")          // single root → titled by it? No: source root shows the source
        // At a source root we show the source's root folders as the "folders" list:
        XCTAssertEqual(c.folders.map(\.name), ["My Productions"])
        XCTAssertEqual(c.crumbs.first?.label, "Drive")     // first crumb = source short name
    }
    func test_insideFolder_showsSubfoldersTracks_breadcrumb_andRecursivePlayAll() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine")
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.title, "My Productions")
        XCTAssertEqual(c.folders.map(\.name), ["House"])   // sub-folder
        XCTAssertEqual(c.tracks.count, 0)                  // "mine" has no direct tracks
        XCTAssertEqual(c.playAll.map(\.title).sorted(), ["h1", "h2"])  // recursive into House
        XCTAssertEqual(c.crumbs.map(\.label), ["Drive", "My Productions"])
    }
    func test_leafFolder_directTracks_playAllEqualsTracks() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openSource("gdrive"); n.openFolder("mine"); n.openFolder("house")
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.folders.count, 0)
        XCTAssertEqual(c.tracks.map(\.title).sorted(), ["h1", "h2"])
        XCTAssertEqual(c.playAll.count, 2)
    }
```
> The source-root case: when `folderIds` is empty we show the source's **root folders** as `folders`. When there's exactly one root, the spec still lists it under "Root Folders" (don't auto-descend). The `title` at a source root is the **source label**; deeper, it's the current folder's name. Adjust the first assertion's expectation to the source label ("Google Drive") if you render the source label there — match whichever the implementation produces and keep it consistent with the view. (Pick: **source root title = source.label**; fix the test to `XCTAssertEqual(c.title, "Google Drive")`.)

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — replace the `folderContent` placeholder comment with:
```swift
    @MainActor
    private static func folderContent(sourceId: String, nav: LibraryNav, index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        let source = try? LibraryStore.source(id: sourceId, ctx)
        let kind = source.flatMap { SourceKind(rawValue: $0.kind) } ?? .local
        var c = BrowseContent(level: .folder)
        c.sourceTint = kind.tintHex
        var crumbs = [BrowseContent.Crumb(label: kind.short, folderDepth: -1)]   // first crumb = source root

        if nav.folderIds.isEmpty {
            // Source root: list the source's root folders.
            c.title = source?.label ?? kind.label
            let roots = (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? []
            c.folders = roots.compactMap { rootNode(for: $0, ctx: ctx) }
            c.tracks = []
            c.playAll = c.folders.flatMap { flatten($0, ctx: ctx) }
            c.crumbs = crumbs
            return c
        }

        // Inside a folder: title + crumbs from the path; sub-folders + direct tracks; recursive play-all.
        var node: FolderNode?
        for (depth, fid) in nav.folderIds.enumerated() {
            node = try? LibraryStore.folderNode(id: fid, ctx)
            crumbs.append(.init(label: node?.name ?? "…", folderDepth: depth))
        }
        c.title = node?.name ?? kind.label
        c.crumbs = crumbs
        if let node {
            c.folders = (try? LibraryStore.childFolders(of: node.id, ctx)) ?? []
            c.tracks = (try? LibraryStore.tracksInFolder(id: node.id, ctx)) ?? []
            c.playAll = flatten(node, ctx: ctx)
        }
        return c
    }

    /// The FolderNode that backs a root folder: cloud roots resolve by `providerFolderId`, local roots by
    /// the stable `nodeId` persisted on the RootFolder (matches the hardened `LibraryIndex.rootNode`).
    @MainActor
    static func rootNode(for root: RootFolder, ctx: ModelContext) -> FolderNode? {
        guard let id = root.providerFolderId ?? root.nodeId else { return nil }
        return try? LibraryStore.folderNode(id: id, ctx)
    }

    /// Depth-first descendant tracks (handoff §3.2 Play All), in folder then child order. `visited`
    /// guards against a cyclic/DAG cache (same guarantee as `LibraryIndex.walk`).
    @MainActor
    static func flatten(_ node: FolderNode, ctx: ModelContext, visited: inout Set<String>) -> [Track] {
        guard visited.insert(node.id).inserted else { return [] }
        var out = (try? LibraryStore.tracksInFolder(id: node.id, ctx)) ?? []
        for childId in node.childFolderIds {
            if let child = try? LibraryStore.folderNode(id: childId, ctx) {
                out += flatten(child, ctx: ctx, visited: &visited)
            }
        }
        return out
    }

    /// Convenience: flatten with a fresh cycle-guard set.
    @MainActor
    static func flatten(_ node: FolderNode, ctx: ModelContext) -> [Track] {
        var visited = Set<String>()
        return flatten(node, ctx: ctx, visited: &visited)
    }
```
> The crumb with `folderDepth: -1` is the source root (tapping it = `LibraryNav` source root, i.e. `jumpTo(folderDepth: 0)` with `folderIds` cleared). The view maps a crumb tap: depth `-1` → clear folderIds; depth `d` → `nav.jumpTo(folderDepth: d+1)` (keep through that crumb). Keep the mapping consistent with `LibraryNav.jumpTo`.

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): folder-level resolver — subfolders, tracks, breadcrumb, recursive Play All`.

---

## Task 4: Resolver — ALL SONGS level

**Files:** Modify `Sources/Model/LibraryBrowse.swift`; extend `Tests/LibraryBrowseTests.swift`.

- [ ] **Step 1: Failing test** — append:
```swift
    func test_allSongs_flatReachableTracks() throws {
        let (ctx, idx) = try fixture()
        let n = LibraryNav(); n.openAllSongs()
        let c = LibraryBrowse.content(for: n, index: idx, ctx: ctx)
        XCTAssertEqual(c.level, .allSongs)
        XCTAssertEqual(c.title, "All Songs")
        XCTAssertEqual(Set(c.tracks.map(\.title)), ["local1", "h1", "h2"])   // reachable only
        XCTAssertEqual(c.playAll.count, 3)
    }
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — add to `LibraryBrowse`:
```swift
    @MainActor
    private static func allSongsContent(index: LibraryIndex, ctx: ModelContext) -> BrowseContent {
        let reachable = index.reachableTrackIds
        let tracks = ((try? LibraryStore.allTracks(ctx)) ?? []).filter { reachable.contains($0.id) }
        var c = BrowseContent(level: .allSongs, title: "All Songs")
        c.tracks = tracks
        c.playAll = tracks
        c.sourceTint = Theme.accentHex
        return c
    }
```
> Add `static let accentHex = "#EFA869"` to `Theme` (Theme/Theme.swift) if not present, so the resolver stays UI-token-free. `allTracks` is already sorted by `dateAdded` desc — All Songs keeps that order.

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): All Songs resolver — flat reachable tracks`.

---

## Task 5: SourceRow + FolderRow + Breadcrumb components

**Files:** Create `Sources/Components/SourceRow.swift`, `FolderRow.swift`, `LibraryBreadcrumb.swift`.

Build to the handoff §3.1/§3.2 mockups, matching existing component style (Theme tokens, 46pt tinted tile, mono subtitles, chevron). No new tests here (covered by the resolver tests + the Task 9 XCUITest). Each is a small, focused `View`.

- [ ] **Step 1: `SourceRow`** — tinted 46pt rounded tile with the source glyph (SF Symbol per kind: local `iphone`, icloud `icloud`, gdrive `cloud`/`externaldrive`), `label` (16/medium), `"\(folders) folders · \(tracks) tracks"` (mono 11.5, text3), a 7pt status dot (green `connected`, amber `needsReauth`, grey `offline`), chevron. Inputs: `source: Source`, `counts: LibraryIndex.Counts`, `onTap`. Tile bg = `Color(hex: source.tintHex).opacity(0.16)`, glyph = `Color(hex: source.tintHex)`. Add `.accessibilityIdentifier("sourceRow-\(source.id)")`.

- [ ] **Step 2: `FolderRow`** — tinted folder glyph (`folder.fill`), `name` (15/medium), recursive `"\(folders) folders · \(tracks) tracks"` or `"\(tracks) tracks"` when no sub-folders (mono), chevron. Inputs: `name`, `tint: String`, `counts`, `onTap`. `.accessibilityIdentifier("folderRow-\(name)")`.

- [ ] **Step 3: `LibraryBreadcrumb`** — back chevron button (`onBack`) + an `HStack` of crumbs joined by " / " in `Theme.mono(11)`; every crumb except the last is a `Button(onTap: depth)`; last is plain `text2`. Inputs: `crumbs: [BrowseContent.Crumb]`, `onCrumb: (Int) -> Void`, `onBack: () -> Void`. `.accessibilityIdentifier("breadcrumb")`; each crumb button `.accessibilityIdentifier("crumb-\(crumb.label)")`.

- [ ] **Step 4: Build to verify it compiles** — `xcodegen generate` then build the app target:
```bash
cd apps/nano-ios && xcodebuild build -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=28DD8D81-668A-4887-98E8-BFE3CC625596' 2>&1 | grep -E "BUILD (SUCCEEDED|FAILED)|error:" | tail
```
Expected: `BUILD SUCCEEDED`. Commit: `feat(ios): SourceRow + FolderRow + breadcrumb components`.

---

## Task 6: Rebuild LibraryScreen as the folder browser

**Files:** Modify `Sources/Screens/LibraryScreen.swift`.

Render `BrowseContent` for the three levels. Replace the flat `@Query` list with: read `LibraryNav` + `LibraryIndex` from the environment, compute `let content = LibraryBrowse.content(for: nav, index: index, ctx: ctx)` (recompute when nav or the track/source/folder stores change — drive it off a `@Query private var tracks` + nav observation so SwiftUI re-renders).

- [ ] **Step 1:** Add `@Environment(LibraryNav.self) private var nav` and `@Environment(LibraryIndex.self) private var index`. Keep `@Query private var tracks` (so the view re-renders on data change) and recompute `content` in `body`.
- [ ] **Step 2:** **Root level:** header "Library" + search/gear glass buttons (keep the existing import `folder` button OR move import to Settings later — keep it for now). Then an "All Songs" accent-tinted row (count = `content.allSongsCount`) that calls `nav.openAllSongs()`. Then a "Sources" section header + `ForEach(content.sources)` → `SourceRow(source:, counts: index.sourceCounts[id] ?? .init(), onTap: { nav.openSource(id) })`. Footer: quiet "Manage sources & root folders in Settings".
- [ ] **Step 3:** **Folder level:** `LibraryBreadcrumb(crumbs: content.crumbs, onCrumb: { mapCrumb($0) }, onBack: { nav.up() })`; big title = `content.title`; if `content.showsPlayAll` a Play All + Shuffle button row (Play All → `engine.play(content.playAll.first!, in: content.playAll, context: playContext)`; Shuffle → `engine.playShuffle(content.playAll, context:)`). "Folders"/"Root Folders" section with `FolderRow`s (`onTap: { nav.openFolder(node.id) }`, counts from `index.folderCounts[node.id]`). "Tracks" section with `NMRow`s (`onTap: { engine.play(track, in: content.tracks, context: playContext) }`). Empty → centered "This folder is empty."
- [ ] **Step 4:** **All Songs level:** breadcrumb/back to root, title "All Songs", flat `NMRow` list over `content.tracks`, play context `.library`.
- [ ] **Step 5: `mapCrumb(_ depth:)`** — depth `-1` → `nav.folderIds = []` (source root); else `nav.jumpTo(folderDepth: depth + 1)`. Define `playContext` per §5.3: folder → `PlayContext(kind: "PLAYING FROM \(source.label.uppercased())", name: content.title)`; all songs → `.library`. (Full Playing-from nav payload is Phase 3 — a plain label is fine here.)
- [ ] **Step 6: Build + run unit suite** — `BUILD SUCCEEDED`, all unit tests still green. Commit: `feat(ios): LibraryScreen renders the folder browser (root/folder/All Songs)`.

> Keep `.fileImporter`, `.sheet(item: detailTrack)`, `.sheet(showSettings)` wiring. `StatTile` may be removed or repurposed — the root now leads with All Songs + Sources, not stat tiles. Removing `StatTile` is fine (note it).

---

## Task 7: RootView owns LibraryNav + LibraryIndex; tab re-tap pops to root

**Files:** Modify `Sources/RootView.swift`, `Sources/Components/GlassTabBar.swift`.

- [ ] **Step 1: GlassTabBar `onReselect`** — add `var onReselect: (Tab) -> Void = { _ in }`; in the Button action: `if tab == selection { onReselect(tab) } else { selection = tab }`.
- [ ] **Step 2: RootView state** — add `@State private var libNav = LibraryNav()` and `@State private var libIndex = LibraryIndex()`. Inject both: `.environment(libNav)` and `.environment(libIndex)`.
- [ ] **Step 3: Rebuild the index** — on `.task`/`.onAppear` and whenever the data changes, call `libIndex.rebuild(from: ctx)`. Simplest reliable approach: a `@Query private var allTracksProbe: [Track]` + `@Query private var sourcesProbe: [Source]` in RootView (DEBUG-independent), and `.onChange(of: allTracksProbe.count)` / `.onChange(of: sourcesProbe.count)` → `libIndex.rebuild(from: ctx)`, plus one rebuild in `.task` at launch. (RootView already has `@Environment(\.modelContext)` behind `#if DEBUG` — promote it to always-available for the rebuild.)
- [ ] **Step 4: Tab re-tap** — `GlassTabBar(selection: $tab, onReselect: { tab in if tab == .library { libNav.reset() } })`.
- [ ] **Step 5: Build + run full suite** — `BUILD SUCCEEDED`, all green. Commit: `feat(ios): RootView owns LibraryNav + LibraryIndex; Library re-tap pops to root`.

> The `LibraryScreen(onSearch:)` call stays. `LibraryIndex.rebuild` is cheap (in-memory walk); rebuilding on data-count change is fine for now. Phase 4 adds explicit rebuilds on connect/disconnect/add-root.

---

## Task 8: XCUITest — drill, back, breadcrumb, tab re-tap, All Songs

**Files:** Create `UITests/LibraryBrowserUITests.swift`.

The app launches with the migrated local source ("On My iPhone") holding the 2 demo tracks under one root. The browser root shows All Songs + the On My iPhone source.

- [ ] **Step 1: Write the UI test** (match the existing `UITests/*` launch pattern — read one first for the `XCUIApplication()` setup / launchArguments):
```swift
import XCTest

final class LibraryBrowserUITests: XCTestCase {
    func test_root_showsAllSongsAndLocalSource_drillAndBack() {
        let app = XCUIApplication(); app.launch()
        // Root: All Songs + the On My iPhone source row.
        XCTAssertTrue(app.staticTexts["All Songs"].waitForExistence(timeout: 5))
        let sourceRow = app.descendants(matching: .any)["sourceRow-local"]
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 5))
        sourceRow.tap()
        // Inside the source: breadcrumb + the root folder "On My iPhone".
        XCTAssertTrue(app.otherElements["breadcrumb"].waitForExistence(timeout: 5)
                      || app.staticTexts["On My iPhone"].waitForExistence(timeout: 5))
        // Drill into the root folder and see the demo tracks.
        app.descendants(matching: .any)["folderRow-On My iPhone"].firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 5))
        // Tab re-tap pops back to the Library root.
        app.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["All Songs"].waitForExistence(timeout: 5))
    }

    func test_allSongs_listsDemoTracks() {
        let app = XCUIApplication(); app.launch()
        app.staticTexts["All Songs"].tap()
        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 5))
    }
}
```
> Read `apps/nano-ios/UITests/WaveformUITests.swift` (or any existing UITest) FIRST to copy the exact launch setup and any required launch arguments. Adjust element queries to match how the row identifiers actually resolve (`buttons`, `otherElements`, `staticTexts`) — run the test, inspect failures, and fix the queries to be robust. The Library tab button label is "Library" (from `Tab.title`).

- [ ] **Step 2: Run the UI test**
```bash
cd apps/nano-ios && xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=28DD8D81-668A-4887-98E8-BFE3CC625596' \
  -only-testing:NanoMetersUITests/LibraryBrowserUITests 2>&1 | grep -E "Test Case|Executed|passed|failed|error:" | tail -25
```
Iterate on the element queries until both tests pass. If a row id doesn't resolve, add/adjust `.accessibilityIdentifier` on the component and re-run.

- [ ] **Step 3: Commit** — `test(ios): XCUITest for the Library folder browser (drill/back/re-tap/All Songs)`.

---

## Phase 2 acceptance
- [ ] `LibraryNav` transitions unit-tested (open/up/jumpTo/reset/goToSource).
- [ ] `LibraryBrowse` resolver unit-tested at root / source-root / folder / leaf / All Songs, incl. recursive Play All and disconnected-source exclusion.
- [ ] Library root lists All Songs + connected sources (canonical order, noRoots/disconnected hidden).
- [ ] Drill in/out, tappable breadcrumb, back, tab-re-tap-to-root all work (XCUITest green on the Nano sim).
- [ ] Play All plays the whole subtree; track tap plays the visible list; empty folder shows the empty state.
- [ ] Full unit + UI suites green; app launches into the browser.

**Next:** Phase 3 — scoped search + Go-to-Source + folder-aware Playing-from (its own plan).
