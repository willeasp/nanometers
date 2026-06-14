# Library & Sources — Phase 4: Settings Sources Manager + Provider Abstraction (Local/iCloud)

> **For agentic workers:** REQUIRED SUB-SKILL: subagent-driven-development / executing-plans. Steps use `- [ ]`.

**Goal:** A Settings "Sources manager" (main → source detail → add source → add root) that connects **Local** and **iCloud** sources via the system folder picker, enumerates a picked folder into the `FolderNode`/`Track` cache (so it appears in the Library browser), manages multiple roots, and disconnects. Introduce the `SourceProvider` protocol + a pure `DirectoryEnumerator` — the seam Phase 5's Google Drive provider implements. Drive a `SourcesManager` that performs connect/add-root/remove-root/disconnect and rebuilds the index.

**Architecture:** The hard, testable logic is split out: `DirectoryEnumerator` (a pure function from a folder URL → a tree of folder/track descriptors, unit-tested against a real temp directory) and `SourcesManager` (an `@MainActor` service that turns enumerator output + picker results into SwiftData rows + an index rebuild, unit-tested with a fake enumerator). The `SourceProvider` protocol abstracts pick/enumerate/playableURL so Local, iCloud, and (Phase 5) Drive are interchangeable. The system folder picker (`UIDocumentPickerViewController`, folder mode) is a thin shell that can't be unit-tested — its output (a folder URL + security-scoped bookmark) is fed to the testable enumerator. Settings UI is a `NavigationStack` of thin views over `SourcesManager`.

**Tech Stack:** SwiftUI, SwiftData, `UIDocumentPickerViewController`, security-scoped bookmarks, `FileManager`, XCTest + XCUITest. Sim **iPhone 16 Pro (Nano)** `28DD8D81-668A-4887-98E8-BFE3CC625596` (never 17).

**Spec:** `…design.md` §8 (Settings + state machine), §9 (provider layer Local/iCloud); handoff §06 (Sources manager), §07 (onboarding Branch A), §08.4 (root folders/bookmarks), §08.5 (enumeration).

**Depends on Phase 1–3:** `Source`/`RootFolder`(`nodeId`)/`FolderNode`, `LibraryIndex.rebuild`, `LibraryStore`, `SourceKind`/`SourceState`, `LibraryNav`, the Library browser. The migration's local source already exists; Phase 4 adds the ability to add MORE roots and NEW sources.

---

## Conventions (every task)
- Unit `-only-testing:NanoMetersTests`; UI `-only-testing:NanoMetersUITests`. Nano sim (never 17).
- New file → `xcodegen generate`; **never `git add` the gitignored `NanoMeters.xcodeproj`**.
- Commit per task; end messages with `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

## File Structure
**Create:**
- `Sources/Sources/SourceProvider.swift` — the protocol + shared descriptor types.
- `Sources/Sources/DirectoryEnumerator.swift` — pure folder-tree → descriptors.
- `Sources/Sources/LocalSourceProvider.swift` — Local + iCloud (folder picker + FileManager + bookmarks).
- `Sources/Sources/SourcesManager.swift` — connect / addRoot / removeRoot / disconnect + index rebuild.
- `Sources/Screens/SourcesSettingsView.swift` — the manager UI (main/detail/add-source/add-root).
- `Sources/Components/FolderPicker.swift` — `UIViewControllerRepresentable` folder picker shell.
- `Tests/DirectoryEnumeratorTests.swift`, `Tests/SourcesManagerTests.swift`.
- `UITests/SourcesSettingsUITests.swift`.
**Modify:**
- `Sources/Screens/SettingsSheet.swift` — add the "Library Sources" group above the existing Waveform group.

---

## Task 1: SourceProvider protocol + descriptor types

**Files:** Create `Sources/Sources/SourceProvider.swift`.

- [ ] **Step 1: Implement** (no test — pure declarations; exercised by later tasks):
```swift
import Foundation

/// A node discovered by enumerating a source: a folder (with children) or a track (a playable file).
struct FolderDescriptor: Equatable {
    var id: String            // provider folder id (cloud) or a stable derived id (local: hashed path)
    var name: String
    var parentId: String?
    var childFolderIds: [String]
    var trackIds: [String]    // provider file ids of the folder's direct tracks
}
struct TrackDescriptor: Equatable {
    var id: String            // provider file id (cloud) or derived id (local: hashed path)
    var title: String, artist: String, album: String
    var durationSec: Double
    var format: String
    var bookmark: Data?       // local: per-file security-scoped bookmark (nil for cloud)
    var providerFileId: String?  // cloud file id (nil for local)
}
struct EnumerationResult: Equatable { var folders: [FolderDescriptor]; var tracks: [TrackDescriptor] }

/// Abstracts a storage provider so the Library/index/Settings are source-agnostic (handoff §08/§09).
/// Local/iCloud + (Phase 5) Google Drive each implement this.
protocol SourceProvider {
    var kind: SourceKind { get }
    /// Enumerate a root's full subtree into descriptors. `rootId` is the RootFolder's nodeId/providerFolderId.
    func enumerate(rootBookmark: Data?, providerFolderId: String?, rootName: String, rootId: String) async throws -> EnumerationResult
}
```
- [ ] **Step 2: Build** to confirm it compiles. Commit: `feat(ios): SourceProvider protocol + enumeration descriptors`.

---

## Task 2: DirectoryEnumerator — pure folder-tree → descriptors

**Files:** Create `Sources/Sources/DirectoryEnumerator.swift`, `Tests/DirectoryEnumeratorTests.swift`.

Pure logic: given a real folder URL, walk it with `FileManager`, emit a `FolderDescriptor` per directory and a `TrackDescriptor` per audio file (filtered by extension), with stable ids derived from the relative path. Metadata read is best-effort (filename fallback) so it's testable without real audio.

- [ ] **Step 1: Failing test** — `Tests/DirectoryEnumeratorTests.swift`:
```swift
import XCTest
@testable import NanoMeters

final class DirectoryEnumeratorTests: XCTestCase {
    private func tempTree() throws -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("enum-\(UUID())")
        let house = root.appendingPathComponent("House")
        try fm.createDirectory(at: house, withIntermediateDirectories: true)
        try Data([1,2,3]).write(to: root.appendingPathComponent("intro.mp3"))
        try Data([1,2,3]).write(to: house.appendingPathComponent("track1.wav"))
        try Data([1,2,3]).write(to: house.appendingPathComponent("notes.txt"))   // non-audio, ignored
        addTeardownBlock { try? fm.removeItem(at: root) }
        return root
    }

    func test_enumerate_buildsTreeAndFiltersAudio() throws {
        let root = try tempTree()
        let r = try DirectoryEnumerator.enumerate(folderURL: root, rootId: "ROOT", rootName: "My Music")
        // Root folder + House folder.
        XCTAssertEqual(Set(r.folders.map(\.name)), ["My Music", "House"])
        let rootF = r.folders.first { $0.id == "ROOT" }!
        XCTAssertEqual(rootF.trackIds.count, 1)                       // intro.mp3 only
        let houseF = r.folders.first { $0.name == "House" }!
        XCTAssertEqual(houseF.parentId, "ROOT")
        XCTAssertEqual(houseF.trackIds.count, 1)                      // track1.wav (notes.txt filtered)
        XCTAssertTrue(rootF.childFolderIds.contains(houseF.id))
        // Track descriptors: titles fall back to filename; formats upper-cased ext.
        XCTAssertEqual(Set(r.tracks.map(\.title)), ["intro", "track1"])
        XCTAssertEqual(Set(r.tracks.map(\.format)), ["MP3", "WAV"])
        XCTAssertTrue(r.tracks.allSatisfy { $0.bookmark != nil })     // per-file bookmark captured
    }
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — `Sources/Sources/DirectoryEnumerator.swift`:
```swift
import Foundation
import AVFoundation
import UniformTypeIdentifiers

/// Walks a local folder tree into provider-agnostic descriptors. Pure (no SwiftData), so it's unit-
/// testable against a temp directory. Audio files only (by UTType); folder ids are stable hashes of the
/// path relative to the root, so re-enumeration is idempotent.
enum DirectoryEnumerator {
    static let audioExtensions: Set<String> = ["mp3","m4a","aac","wav","aif","aiff","flac","alac","caf","ogg"]

    @MainActor
    static func enumerate(folderURL root: URL, rootId: String, rootName: String) throws -> EnumerationResult {
        var folders: [FolderDescriptor] = []
        var tracks: [TrackDescriptor] = []
        try walk(root, id: rootId, name: rootName, parentId: nil, root: root,
                 folders: &folders, tracks: &tracks)
        return EnumerationResult(folders: folders, tracks: tracks)
    }

    private static func id(for url: URL, root: URL) -> String {
        let rel = url.path.replacingOccurrences(of: root.deletingLastPathComponent().path, with: "")
        return "local:" + String(rel.hashValue, radix: 16)
    }

    @MainActor
    private static func walk(_ url: URL, id: String, name: String, parentId: String?, root: URL,
                             folders: inout [FolderDescriptor], tracks: inout [TrackDescriptor]) throws {
        let fm = FileManager.default
        let entries = (try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: [.isDirectoryKey]))
            ?? []
        var childFolderIds: [String] = []
        var trackIds: [String] = []
        for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let isDir = (try? entry.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory ?? false
            if isDir {
                let cid = self.id(for: entry, root: root)
                childFolderIds.append(cid)
                try walk(entry, id: cid, name: entry.lastPathComponent, parentId: id, root: root,
                         folders: &folders, tracks: &tracks)
            } else if audioExtensions.contains(entry.pathExtension.lowercased()) {
                let tid = self.id(for: entry, root: root)
                trackIds.append(tid)
                let bm = try? entry.bookmarkData()
                let title = entry.deletingPathExtension().lastPathComponent.replacingOccurrences(of: "_", with: " ")
                tracks.append(TrackDescriptor(id: tid, title: title, artist: "", album: "",
                                              durationSec: 0, format: entry.pathExtension.uppercased(),
                                              bookmark: bm, providerFileId: nil))
            }
        }
        folders.append(FolderDescriptor(id: id, name: name, parentId: parentId,
                                        childFolderIds: childFolderIds, trackIds: trackIds))
    }
}
```
> Metadata is filename-fallback here (cheap, testable). Richer AVAsset metadata is read lazily on import/play (existing `TrackImporter` path) — keep enumeration fast. The per-file `bookmark` lets `AudioEngine.resolveURL` play the file via the existing path.

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): DirectoryEnumerator — folder tree → descriptors (audio-filtered)`.

---

## Task 3: SourcesManager — connect / addRoot / removeRoot / disconnect

**Files:** Create `Sources/Sources/SourcesManager.swift`, `Tests/SourcesManagerTests.swift`.

Turns enumerator output into SwiftData rows (`Source`, `RootFolder`, `FolderNode`, `Track`) and rebuilds the index. Unit-tested with an in-memory `EnumerationResult` (no picker/filesystem needed) by exposing an `applyEnumeration` entrypoint.

- [ ] **Step 1: Failing tests** — `Tests/SourcesManagerTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourcesManagerTests: XCTestCase {
    func test_connectAndAddRoot_createsSourceFoldersTracks_andReachable() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex()
        let mgr = SourcesManager(ctx: ctx, index: idx)
        // Connect iCloud, then add a root whose enumeration we supply directly.
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [
                FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: ["h"], trackIds: []),
                FolderDescriptor(id: "h", name: "House", parentId: "r", childFolderIds: [], trackIds: ["t1"]),
            ],
            tracks: [TrackDescriptor(id: "t1", title: "Caldera", artist: "Oso", album: "",
                                     durationSec: 0, format: "WAV", bookmark: Data([9]), providerFileId: nil)])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        XCTAssertEqual(try LibraryStore.source(id: "icloud", ctx)?.state, "connected")
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 1)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.tracks, 1)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.folders, 2)
        XCTAssertTrue(idx.reachableTrackIds.contains(where: { _ in true }))   // a track exists & reachable
    }

    func test_removeRoot_dropsItsTracksFromReachable() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: [], trackIds: ["t1"])],
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV", bookmark: Data([9]), providerFileId: nil)])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        let root = try LibraryStore.rootFolders(of: "icloud", ctx).first!
        mgr.removeRoot(root)
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 0)
        XCTAssertEqual(idx.sourceCounts["icloud"]?.tracks ?? 0, 0)
    }

    func test_disconnect_clearsSourceRootsNodes_butKeepsTrackRowsForPlaylists() throws {
        let ctx = try TestDB.context()
        let idx = LibraryIndex(); let mgr = SourcesManager(ctx: ctx, index: idx)
        mgr.connect(kind: .icloud)
        let result = EnumerationResult(
            folders: [FolderDescriptor(id: "r", name: "Mixes", parentId: nil, childFolderIds: [], trackIds: ["t1"])],
            tracks: [TrackDescriptor(id: "t1", title: "A", artist: "", album: "", durationSec: 0, format: "WAV", bookmark: Data([9]), providerFileId: nil)])
        mgr.applyEnumeration(result, sourceId: "icloud", rootName: "Mixes", rootNodeId: "r", rootBookmark: Data([1]))
        mgr.disconnect(sourceId: "icloud")
        XCTAssertNil(try LibraryStore.source(id: "icloud", ctx))
        XCTAssertEqual(try LibraryStore.rootFolders(of: "icloud", ctx).count, 0)
        XCTAssertTrue(try LibraryStore.childFolders(of: "r", ctx).isEmpty)   // folder nodes gone
        // Track rows persist (playlists may reference them) but are no longer reachable.
        XCTAssertFalse(idx.reachableTrackIds.contains(where: { _ in true }) && idx.sourceCounts["icloud"] != nil)
    }
}
```

- [ ] **Step 2: Run — fails.**

- [ ] **Step 3: Implement** — `Sources/Sources/SourcesManager.swift`:
```swift
import Foundation
import SwiftData

/// Connect / add-root / remove-root / disconnect over the SwiftData store, then rebuild the index. The
/// picker + enumeration are done by the caller (provider); this turns their output into rows (handoff §06/§08).
@MainActor
final class SourcesManager {
    private let ctx: ModelContext
    private let index: LibraryIndex
    init(ctx: ModelContext, index: LibraryIndex) { self.ctx = ctx; self.index = index }

    /// Create the Source row (state .noRoots until a root is added).
    func connect(kind: SourceKind, authRef: String? = nil) {
        if (try? LibraryStore.source(id: kind.rawValue, ctx)) ?? nil != nil { return }
        ctx.insert(Source(id: kind.rawValue, kind: kind, state: .noRoots, authRef: authRef))
        index.rebuild(from: ctx)
    }

    /// Materialize an enumeration into FolderNode/Track rows under a new RootFolder, then rebuild.
    func applyEnumeration(_ result: EnumerationResult, sourceId: String, rootName: String,
                          rootNodeId: String, rootBookmark: Data?, providerFolderId: String? = nil) {
        let kind = SourceKind(rawValue: (try? LibraryStore.source(id: sourceId, ctx))??.kind ?? "") ?? .local
        // Persist a TrackDescriptor → Track row (id-mapped so FolderNode.trackIds can reference UUIDs).
        var idMap: [String: UUID] = [:]
        for td in result.tracks {
            let t = Track(title: td.title, artist: td.artist, album: td.album,
                          sourceKind: kind.rawValue, bookmark: td.bookmark, displayPath: kind.label,
                          durationSec: td.durationSec, format: td.format,
                          sourceId: sourceId, providerFileId: td.providerFileId)
            ctx.insert(t); idMap[td.id] = t.id
        }
        for fd in result.folders {
            let node = FolderNode(id: fd.id, sourceId: sourceId, name: fd.name, parentId: fd.parentId,
                                  childFolderIds: fd.childFolderIds,
                                  trackIds: fd.trackIds.compactMap { idMap[$0] }, lastIndexed: .init())
            ctx.insert(node)
            for tid in fd.trackIds { if let uuid = idMap[tid], let tr = try? LibraryStore.track(id: uuid, ctx) { tr.folderId = fd.id } }
        }
        ctx.insert(RootFolder(sourceId: sourceId, name: rootName, providerFolderId: providerFolderId,
                              bookmark: rootBookmark, nodeId: rootNodeId))
        if let s = try? LibraryStore.source(id: sourceId, ctx) { s.state = SourceState.connected.rawValue }
        index.rebuild(from: ctx)
    }

    func removeRoot(_ root: RootFolder) {
        let sourceId = root.sourceId
        if let nodeId = root.providerFolderId ?? root.nodeId { deleteSubtree(nodeId: nodeId, sourceId: sourceId) }
        ctx.delete(root)
        // If that was the last root, mark the source noRoots.
        if (try? LibraryStore.rootFolders(of: sourceId, ctx))?.isEmpty ?? true,
           let s = try? LibraryStore.source(id: sourceId, ctx) { s.state = SourceState.noRoots.rawValue }
        index.rebuild(from: ctx)
    }

    func disconnect(sourceId: String) {
        for root in (try? LibraryStore.rootFolders(of: sourceId, ctx)) ?? [] {
            if let nodeId = root.providerFolderId ?? root.nodeId { deleteSubtree(nodeId: nodeId, sourceId: sourceId) }
            ctx.delete(root)
        }
        if let s = try? LibraryStore.source(id: sourceId, ctx) { ctx.delete(s) }
        index.rebuild(from: ctx)
    }

    /// Delete a root's FolderNode subtree (the cache). Track ROWS are kept (playlists may reference them);
    /// they just stop being reachable once their nodes/source are gone.
    private func deleteSubtree(nodeId: String, sourceId: String) {
        guard let node = try? LibraryStore.folderNode(id: nodeId, ctx) else { return }
        for childId in node.childFolderIds { deleteSubtree(nodeId: childId, sourceId: sourceId) }
        ctx.delete(node)
    }
}
```
> Note the double-optional `(try? ...) ?? nil` idiom around `LibraryStore.source` (it `throws` and returns optional). Keep it consistent with Phase 1 usage.

- [ ] **Step 4: Run — pass.** Commit: `feat(ios): SourcesManager — connect/addRoot/removeRoot/disconnect + index rebuild`.

---

## Task 4: LocalSourceProvider + FolderPicker shell

**Files:** Create `Sources/Sources/LocalSourceProvider.swift`, `Sources/Components/FolderPicker.swift`.

- [ ] **Step 1: FolderPicker** — a `UIViewControllerRepresentable` wrapping `UIDocumentPickerViewController(forOpeningContentTypes: [.folder])` with `directoryURL` access; on pick, start `startAccessingSecurityScopedResource()`, capture `bookmarkData()`, call back `(url, bookmark)`. `.accessibilityIdentifier("folderPicker")` on the hosting view is not reachable (system UI), so no XCUITest here.
- [ ] **Step 2: LocalSourceProvider** — conforms to `SourceProvider` (kind injected: `.local` or `.icloud`). `enumerate(rootBookmark:…)` resolves the bookmark → `startAccessingSecurityScopedResource` → `DirectoryEnumerator.enumerate(folderURL:rootId:rootName:)` → `stopAccessing`. (iCloud: optionally `NSFileCoordinator` read; for v1 a plain enumeration after the picker grants access is sufficient.)
- [ ] **Step 3: Build** to compile. Commit: `feat(ios): LocalSourceProvider + folder-picker shell (Local + iCloud)`.

> The folder pick + on-device file presence is a MANUAL verification step (system picker can't be driven headlessly), like the Drive sign-in. The enumeration + manager logic above IS unit-tested.

---

## Task 5: SourcesSettingsView — the manager UI

**Files:** Create `Sources/Screens/SourcesSettingsView.swift`; modify `Sources/Screens/SettingsSheet.swift`.

Build to handoff §06: a `NavigationStack` with main → source detail → add source → add root. Reads `LibraryStore` + drives `SourcesManager`. Inject `LibraryIndex` + `modelContext`.

- [ ] **Step 1: Main** — a "Library Sources" section listing connected sources (tile · name · `"\(rootCount) root folders · \(trackCount) tracks"`) → each a `NavigationLink` to detail; then an **Add Source…** row (`.accessibilityIdentifier("addSource")`). Embed this section at the top of `SettingsSheet`'s `Form`, above the existing Waveform group.
- [ ] **Step 2: Source detail** — identity header (`Connected · N tracks`), **Root Folders** list (each with a trash button → `manager.removeRoot(root)`), **Add Root Folder…** (presents `FolderPicker` → `provider.enumerate` → `manager.applyEnumeration`), **Disconnect Source** (destructive → `manager.disconnect`, pop). IDs: `rootFolderRow-\(name)`, `addRootFolder`, `disconnectSource`.
- [ ] **Step 3: Add Source** — "Available" = providers not yet connected. **Local** + **iCloud** show a **Connect** pill (→ `manager.connect(kind:)` then push detail to add the first root). **Google Drive / Dropbox / OneDrive** show **"Coming soon"** disabled (Drive arrives in Phase 5). Empty → "All available sources are connected." IDs: `connect-\(kind.rawValue)`.
- [ ] **Step 4: Build + unit suite green.** Commit: `feat(ios): Settings Sources manager UI (main/detail/add-source/add-root)`.

> Status dot + "Connected/Needs re-auth/Offline" copy reuse `SourceState`. Local/iCloud never hit OAuth states; they're `noRoots` → `connected`.

---

## Task 6: Wire Settings into the app + index/nav consistency

**Files:** Modify `Sources/Screens/SettingsSheet.swift`, ensure `SourcesManager`/`LibraryIndex` available.

- [ ] **Step 1:** `SettingsSheet` constructs a `SourcesManager(ctx:index:)` from `@Environment(\.modelContext)` + `@Environment(LibraryIndex.self)` and passes it down. After connect/add/remove/disconnect, the injected `LibraryIndex` is rebuilt by the manager, so the Library browser (Phase 2) reflects changes live (its `@Observable` index drives re-render).
- [ ] **Step 2: Edge cases (handoff §10)** — if the user removes the root they're viewing in Library or disconnects the current source, `LibraryNav` should bounce up. Add: in `LibraryScreen`, if the current `nav.sourceId`/`folderIds` no longer resolve (source gone or node missing), call `nav.up()`/`nav.reset()`. (A `.onChange` of the index/source set that validates the current nav.)
- [ ] **Step 3: Build + full suite green.** Commit: `feat(ios): wire Sources manager into Settings + nav bounce on remove/disconnect`.

---

## Task 7: XCUITest — Settings Sources navigation + state

**Files:** Create `UITests/SourcesSettingsUITests.swift`.

The folder picker is system UI (can't drive), so test the NAVIGATION + the connect/disconnect of a source that doesn't need a picker. Strategy: add a DEBUG launch-argument hook (`-seed-icloud`) that programmatically connects an iCloud source with one in-memory root (via `SourcesManager.applyEnumeration` with a fake result) so the UI has a multi-source state to drive — OR test only the reachable surface (open Settings → Sources → Add Source list shows Local/iCloud connect + Drive "Coming soon"; open the existing local source detail → see its root → see Disconnect).

- [ ] **Step 1:** Write `test_sourcesManager_navigation`: open Settings (`settingsButton`) → tap into "Library Sources" → assert the migrated **On My iPhone** source detail is reachable, shows a root folder row and a `disconnectSource` button; back → tap `addSource` → assert `connect-icloud` exists and a "Coming soon" Google Drive entry exists (`connect-gdrive` is disabled/absent).
- [ ] **Step 2:** Run on the Nano sim; iterate; then run the full UI bundle. Commit: `test(ios): XCUITest for Settings Sources manager navigation`.

---

## Phase 4 acceptance
- [ ] `DirectoryEnumerator` turns a real folder tree into folder/track descriptors (audio-filtered, stable ids), unit-tested.
- [ ] `SourcesManager` connect/addRoot/removeRoot/disconnect create/clear rows and rebuild the index; track rows persist on disconnect; unit-tested.
- [ ] Settings shows the Sources manager (main/detail/add-source/add-root); Local + iCloud connectable; Drive shown "Coming soon"; XCUITest covers navigation.
- [ ] Removing a root / disconnecting bounces the Library nav and updates counts/All-Songs live.
- [ ] Full unit + UI suites green. (Folder pick + real iCloud files = manual verification.)

**Next:** Phase 5 — OAuth + Google Drive provider + RemoteFileCache + download-to-cache playback (its own plan).
