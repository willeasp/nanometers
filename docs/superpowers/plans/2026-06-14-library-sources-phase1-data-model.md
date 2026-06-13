# Library & Sources — Phase 1: Data Model + Migration + LibraryIndex

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the `Source` / `RootFolder` / `FolderNode` data model, migrate existing tracks under a seeded "On My iPhone" source, and build the `LibraryIndex` that derives reachable tracks, recursive counts, and trackId→path — the foundation the folder-browser UI (Phase 2) renders from. The app keeps showing the flat list this phase; nothing user-visible changes yet.

**Architecture:** Everything is string-id keyed (no SwiftData relationships), matching the codebase's existing `Playlist.itemIDs: [UUID]` choice ("SwiftData relationships aren't reliably ordered"). New `@Model` types are added to a single `AppSchema.allModels` list used by the app container. Adding optional fields to `Track` + new model types is an **automatic lightweight SwiftData migration** (no `VersionedSchema` needed). A separate **data** migration (`SourcesMigration`) runs idempotently at launch to attach pre-existing tracks to a seeded local source. `LibraryIndex` is a pure derivation over the store, unit-tested against fixtures.

**Tech Stack:** Swift 5.10, SwiftData, XCTest (`@MainActor`, in-memory `ModelContainer`), XcodeGen. Tests run on the **iPhone 16 Pro (Nano)** simulator: `id=28DD8D81-668A-4887-98E8-BFE3CC625596`.

**Spec:** `docs/superpowers/specs/2026-06-14-library-and-sources-design.md` (§4 data model, §6 LibraryIndex, §11 migration).

---

## Conventions for every task

- **Run tests** (single bundle, fast):
  ```bash
  cd apps/nano-ios && xcodebuild test \
    -project NanoMeters.xcodeproj -scheme NanoMeters \
    -destination 'platform=iOS Simulator,id=28DD8D81-668A-4887-98E8-BFE3CC625596' \
    -only-testing:NanoMetersTests 2>&1 | grep -E "Executed|TEST (SUCCEEDED|FAILED)|error:" | tail -20
  ```
- **Regenerate the project** only after creating a NEW file (XcodeGen globs `Sources/`/`Tests/`, but the `.xcodeproj` must be regenerated to pick up new files):
  ```bash
  cd apps/nano-ios && xcodegen generate
  ```
- New source files go under `apps/nano-ios/Sources/...`; new tests under `apps/nano-ios/Tests/...`.
- Commit after each task (Conventional Commits, lead with the change). End commit messages with:
  `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`

---

## File Structure

**Create:**
- `Sources/Model/SourceState.swift` — the connection-state enum (`disconnected … offline`).
- `Sources/Model/Source.swift` — `@Model Source` (a connected provider account).
- `Sources/Model/RootFolder.swift` — `@Model RootFolder` (a chosen entryway under a source).
- `Sources/Model/FolderNode.swift` — `@Model FolderNode` (cached browse-tree node).
- `Sources/Model/AppSchema.swift` — the single list of `@Model` types for the container.
- `Sources/Model/LibraryIndex.swift` — derived reachable set / counts / paths.
- `Sources/Import/SourcesMigration.swift` — idempotent data migration seeding the local source.
- `Tests/SourceModelTests.swift`, `Tests/FolderNodeTests.swift`, `Tests/SourcesMigrationTests.swift`, `Tests/LibraryIndexTests.swift`, `Tests/SourceKindTests.swift`.
- `Tests/TestDB.swift` — shared in-memory container helper.

**Modify:**
- `Sources/Model/SourceKind.swift` — add `short`, `tintHex`, `canonicalOrder`.
- `Sources/Model/Track.swift` — add `sourceId`, `providerFileId`, `folderId` (optional).
- `Sources/Model/LibraryStore.swift` — add source/root/folder fetch helpers.
- `Sources/NanoMetersApp.swift` — container uses `AppSchema`; run `SourcesMigration` after `DemoSeed`.
- `Sources/Import/TrackImporter.swift` — stamp `sourceId`/`folderId` + append to the local root node.

---

## Task 1: SourceKind tint/order + SourceState enum

**Files:**
- Modify: `apps/nano-ios/Sources/Model/SourceKind.swift`
- Create: `apps/nano-ios/Sources/Model/SourceState.swift`
- Test: `apps/nano-ios/Tests/SourceKindTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/nano-ios/Tests/SourceKindTests.swift`:
```swift
import XCTest
@testable import NanoMeters

final class SourceKindTests: XCTestCase {
    func test_canonicalOrder_isLocalFirst_thenICloudThenDrive() {
        XCTAssertEqual(SourceKind.local.canonicalOrder, 0)
        XCTAssertEqual(SourceKind.icloud.canonicalOrder, 1)
        XCTAssertEqual(SourceKind.gdrive.canonicalOrder, 2)
        XCTAssertLessThan(SourceKind.gdrive.canonicalOrder, SourceKind.dropbox.canonicalOrder)
    }

    func test_tintHex_matchesHandoffPalette() {
        XCTAssertEqual(SourceKind.local.tintHex, "#B990F5")
        XCTAssertEqual(SourceKind.gdrive.tintHex, "#6FCF72")
    }

    func test_short_isAbbreviated() {
        XCTAssertEqual(SourceKind.gdrive.short, "Drive")
        XCTAssertEqual(SourceKind.local.short, "iPhone")
    }

    func test_sourceState_roundTripsRawValue() {
        XCTAssertEqual(SourceState(rawValue: "connected"), .connected)
        XCTAssertEqual(SourceState.needsReauth.rawValue, "needsReauth")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run the test command above.
Expected: FAIL — `value of type 'SourceKind' has no member 'canonicalOrder'` / `cannot find 'SourceState'`.

- [ ] **Step 3: Write minimal implementation**

Create `apps/nano-ios/Sources/Model/SourceState.swift`:
```swift
import Foundation

/// Connection lifecycle of a `Source` (handoff §07). Drives the Library status dot + Settings copy.
enum SourceState: String, CaseIterable {
    case disconnected   // not added
    case authorizing    // OAuth session in flight
    case connected      // valid access + ≥1 root
    case noRoots        // connected but no root chosen → hidden from Library
    case needsReauth    // refresh failed / revoked → amber dot
    case offline        // unreachable → grey dot, cached metadata browsable
}
```

Append to `apps/nano-ios/Sources/Model/SourceKind.swift` (inside the enum, after `label`):
```swift
    /// Abbreviated name for breadcrumbs / first crumb (handoff §3.2).
    var short: String {
        switch self {
        case .local: "iPhone"
        case .icloud: "iCloud"
        case .gdrive: "Drive"
        case .onedrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }

    /// Per-source tint for icon tiles / folder glyphs (handoff §01).
    var tintHex: String {
        switch self {
        case .local: "#B990F5"
        case .icloud: "#5EC8C0"
        case .gdrive: "#6FCF72"
        case .dropbox: "#6AA6FF"
        case .onedrive: "#8AB4F8"
        }
    }

    /// Fixed Library-root order, independent of connection order (handoff §3.1).
    var canonicalOrder: Int {
        switch self {
        case .local: 0
        case .icloud: 1
        case .gdrive: 2
        case .dropbox: 3
        case .onedrive: 4
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the test command. Expected: the 4 new tests PASS (regenerate the project first since a new file was added).
```bash
cd apps/nano-ios && xcodegen generate && cd - >/dev/null
```
Then run the test command. Expected: `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Model/SourceKind.swift apps/nano-ios/Sources/Model/SourceState.swift apps/nano-ios/Tests/SourceKindTests.swift apps/nano-ios/NanoMeters.xcodeproj
git commit -m "feat(ios): SourceKind tint/short/order + SourceState enum

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: AppSchema + shared test container + wire the app container

**Files:**
- Create: `apps/nano-ios/Sources/Model/AppSchema.swift`, `apps/nano-ios/Tests/TestDB.swift`
- Modify: `apps/nano-ios/Sources/NanoMetersApp.swift`

This introduces one place to list models and one place tests build a container, so later tasks add a model with a single edit. No behavior change — existing 45 tests must still pass.

- [ ] **Step 1: Create `AppSchema`**

Create `apps/nano-ios/Sources/Model/AppSchema.swift`:
```swift
import SwiftData

/// The single source of truth for which `@Model` types live in the container. The app and the test
/// harness both build from this, so adding a model is a one-line change here.
enum AppSchema {
    static let allModels: [any PersistentModel.Type] = [
        Track.self, Playlist.self,
    ]
    static var schema: Schema { Schema(allModels) }
}
```

- [ ] **Step 2: Create the shared test helper**

Create `apps/nano-ios/Tests/TestDB.swift`:
```swift
import SwiftData
@testable import NanoMeters

/// In-memory container built from the real `AppSchema`, so tests cover the same model set the app ships.
enum TestDB {
    @MainActor
    static func context() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: AppSchema.schema, configurations: config)
        return ModelContext(container)
    }
}
```

- [ ] **Step 3: Wire the app container to AppSchema**

In `apps/nano-ios/Sources/NanoMetersApp.swift`, replace the `ModelContainer(for:)` line:
```swift
            container = try ModelContainer(for: AppSchema.schema)
```
(Leave the `DemoSeed.seedIfEmpty` line as-is for now.)

- [ ] **Step 4: Run tests to verify no regression**

```bash
cd apps/nano-ios && xcodegen generate && cd - >/dev/null
```
Run the test command. Expected: `Executed 49 tests, with 0 failures` (45 existing + 4 from Task 1), `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Model/AppSchema.swift apps/nano-ios/Tests/TestDB.swift apps/nano-ios/Sources/NanoMetersApp.swift apps/nano-ios/NanoMeters.xcodeproj
git commit -m "refactor(ios): centralize SwiftData model list in AppSchema

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: Source model + LibraryStore.allSources

**Files:**
- Create: `apps/nano-ios/Sources/Model/Source.swift`
- Modify: `apps/nano-ios/Sources/Model/AppSchema.swift`, `apps/nano-ios/Sources/Model/LibraryStore.swift`
- Test: `apps/nano-ios/Tests/SourceModelTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/nano-ios/Tests/SourceModelTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourceModelTests: XCTestCase {
    func test_allSources_sortedByCanonicalOrder_regardlessOfInsertOrder() throws {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))   // inserted first
        ctx.insert(Source(id: "local", kind: .local, state: .connected))
        let sources = try LibraryStore.allSources(ctx)
        XCTAssertEqual(sources.map(\.id), ["local", "gdrive"])
    }

    func test_source_defaultsFromKind() throws {
        let ctx = try TestDB.context()
        let s = Source(id: "gdrive", kind: .gdrive, state: .noRoots)
        ctx.insert(s)
        let fetched = try LibraryStore.source(id: "gdrive", ctx)
        XCTAssertEqual(fetched?.label, "Google Drive")
        XCTAssertEqual(fetched?.tintHex, "#6FCF72")
        XCTAssertEqual(fetched?.canonicalOrder, 2)
        XCTAssertEqual(fetched?.state, "noRoots")
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `cannot find 'Source' in scope` / `LibraryStore` has no member `allSources`.

- [ ] **Step 3: Write minimal implementation**

Create `apps/nano-ios/Sources/Model/Source.swift`:
```swift
import Foundation
import SwiftData

/// A connected storage provider account (handoff §09). String-id keyed (`"local"`/`"icloud"`/`"gdrive"`);
/// roots/folders/tracks reference it by `sourceId`, not a SwiftData relationship.
@Model
final class Source {
    @Attribute(.unique) var id: String
    var kind: String            // SourceKind.rawValue
    var label: String
    var tintHex: String
    var state: String           // SourceState.rawValue
    var authRef: String?        // Keychain account key (cloud only); never the token itself
    var canonicalOrder: Int

    init(id: String, kind: SourceKind, state: SourceState, authRef: String? = nil) {
        self.id = id
        self.kind = kind.rawValue
        self.label = kind.label
        self.tintHex = kind.tintHex
        self.state = state.rawValue
        self.authRef = authRef
        self.canonicalOrder = kind.canonicalOrder
    }
}
```

Add `Source.self` to `AppSchema.allModels`:
```swift
    static let allModels: [any PersistentModel.Type] = [
        Track.self, Playlist.self, Source.self,
    ]
```

Append to `apps/nano-ios/Sources/Model/LibraryStore.swift` (inside the enum):
```swift
    static func allSources(_ ctx: ModelContext) throws -> [Source] {
        try ctx.fetch(FetchDescriptor<Source>(sortBy: [SortDescriptor(\.canonicalOrder)]))
    }

    static func source(id: String, _ ctx: ModelContext) throws -> Source? {
        var d = FetchDescriptor<Source>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }
```

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd apps/nano-ios && xcodegen generate && cd - >/dev/null
```
Run the test command. Expected: 2 new tests PASS, `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Model/Source.swift apps/nano-ios/Sources/Model/AppSchema.swift apps/nano-ios/Sources/Model/LibraryStore.swift apps/nano-ios/Tests/SourceModelTests.swift apps/nano-ios/NanoMeters.xcodeproj
git commit -m "feat(ios): Source @Model + LibraryStore.allSources/source(id:)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: RootFolder model + LibraryStore.rootFolders(of:)

**Files:**
- Create: `apps/nano-ios/Sources/Model/RootFolder.swift`
- Modify: `apps/nano-ios/Sources/Model/AppSchema.swift`, `apps/nano-ios/Sources/Model/LibraryStore.swift`
- Test: `apps/nano-ios/Tests/SourceModelTests.swift` (extend)

- [ ] **Step 1: Write the failing test**

Append to `apps/nano-ios/Tests/SourceModelTests.swift`:
```swift
    func test_rootFolders_filteredBySource_inAddOrder() throws {
        let ctx = try TestDB.context()
        let early = Date(timeIntervalSince1970: 100)
        let later = Date(timeIntervalSince1970: 200)
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "gd-mine", dateAdded: early))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "DJ Crate", providerFolderId: "gd-crate", dateAdded: later))
        ctx.insert(RootFolder(sourceId: "local", name: "On My iPhone", bookmark: Data([1,2]), dateAdded: early))
        let driveRoots = try LibraryStore.rootFolders(of: "gdrive", ctx)
        XCTAssertEqual(driveRoots.map(\.name), ["My Productions", "DJ Crate"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `cannot find 'RootFolder' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `apps/nano-ios/Sources/Model/RootFolder.swift`:
```swift
import Foundation
import SwiftData

/// A chosen entryway under a `Source` (handoff §09). Cloud roots persist a stable `providerFolderId`;
/// local/iCloud roots persist a security-scoped `bookmark`. A source may have many, side by side.
@Model
final class RootFolder {
    @Attribute(.unique) var id: UUID
    var sourceId: String
    var name: String
    var providerFolderId: String?
    var bookmark: Data?
    var dateAdded: Date

    init(id: UUID = UUID(), sourceId: String, name: String,
         providerFolderId: String? = nil, bookmark: Data? = nil, dateAdded: Date = .init()) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.providerFolderId = providerFolderId
        self.bookmark = bookmark
        self.dateAdded = dateAdded
    }
}
```

Add `RootFolder.self` to `AppSchema.allModels`.

Append to `LibraryStore`:
```swift
    static func rootFolders(of sourceId: String, _ ctx: ModelContext) throws -> [RootFolder] {
        try ctx.fetch(FetchDescriptor<RootFolder>(
            predicate: #Predicate { $0.sourceId == sourceId },
            sortBy: [SortDescriptor(\.dateAdded)]))
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Regenerate + run. Expected: new test PASSES, `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Model/RootFolder.swift apps/nano-ios/Sources/Model/AppSchema.swift apps/nano-ios/Sources/Model/LibraryStore.swift apps/nano-ios/Tests/SourceModelTests.swift apps/nano-ios/NanoMeters.xcodeproj
git commit -m "feat(ios): RootFolder @Model + LibraryStore.rootFolders(of:)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: FolderNode model + LibraryStore folder helpers

**Files:**
- Create: `apps/nano-ios/Sources/Model/FolderNode.swift`
- Modify: `apps/nano-ios/Sources/Model/AppSchema.swift`, `apps/nano-ios/Sources/Model/LibraryStore.swift`
- Test: `apps/nano-ios/Tests/FolderNodeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/nano-ios/Tests/FolderNodeTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class FolderNodeTests: XCTestCase {
    func test_folderNode_byId_andChildren() throws {
        let ctx = try TestDB.context()
        ctx.insert(FolderNode(id: "root", sourceId: "gdrive", name: "My Productions",
                              parentId: nil, childFolderIds: ["house", "dnb"]))
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "root"))
        ctx.insert(FolderNode(id: "dnb", sourceId: "gdrive", name: "Drum & Bass", parentId: "root"))
        let root = try LibraryStore.folderNode(id: "root", ctx)
        XCTAssertEqual(root?.childFolderIds, ["house", "dnb"])
        let children = try LibraryStore.childFolders(of: "root", ctx)
        XCTAssertEqual(Set(children.map(\.name)), ["House", "Drum & Bass"])
    }

    func test_tracksInFolder_resolvesIdsInOrder_skippingDangling() throws {
        let ctx = try TestDB.context()
        let t1 = Track(title: "One", artist: "", album: "")
        let t2 = Track(title: "Two", artist: "", album: "")
        [t1, t2].forEach(ctx.insert)
        ctx.insert(FolderNode(id: "f", sourceId: "local", name: "F",
                              trackIds: [t2.id, UUID(), t1.id]))   // middle id is dangling
        let tracks = try LibraryStore.tracksInFolder(id: "f", ctx)
        XCTAssertEqual(tracks.map(\.title), ["Two", "One"])
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `cannot find 'FolderNode' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `apps/nano-ios/Sources/Model/FolderNode.swift`:
```swift
import Foundation
import SwiftData

/// A cached node of a source's browse tree (handoff §09). Rebuildable from the provider, so it is a
/// plain id-keyed cache: children and tracks are stored as ordered id arrays, not relationships.
@Model
final class FolderNode {
    @Attribute(.unique) var id: String     // provider folder id, or a derived id for local folders
    var sourceId: String
    var name: String
    var parentId: String?                  // nil at a root folder
    var childFolderIds: [String]
    var trackIds: [UUID]
    var cursorOrEtag: String?              // delta/pagination token for background re-index
    var lastIndexed: Date?

    init(id: String, sourceId: String, name: String, parentId: String? = nil,
         childFolderIds: [String] = [], trackIds: [UUID] = [],
         cursorOrEtag: String? = nil, lastIndexed: Date? = nil) {
        self.id = id
        self.sourceId = sourceId
        self.name = name
        self.parentId = parentId
        self.childFolderIds = childFolderIds
        self.trackIds = trackIds
        self.cursorOrEtag = cursorOrEtag
        self.lastIndexed = lastIndexed
    }
}
```

Add `FolderNode.self` to `AppSchema.allModels`.

Append to `LibraryStore`:
```swift
    static func folderNode(id: String, _ ctx: ModelContext) throws -> FolderNode? {
        var d = FetchDescriptor<FolderNode>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    static func childFolders(of parentId: String, _ ctx: ModelContext) throws -> [FolderNode] {
        try ctx.fetch(FetchDescriptor<FolderNode>(predicate: #Predicate { $0.parentId == parentId }))
    }

    /// Resolve a folder's direct tracks in stored order, skipping dangling ids.
    static func tracksInFolder(id: String, _ ctx: ModelContext) throws -> [Track] {
        guard let node = try folderNode(id: id, ctx) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: try allTracks(ctx).map { ($0.id, $0) })
        return node.trackIds.compactMap { byID[$0] }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Regenerate + run. Expected: 2 new tests PASS, `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Model/FolderNode.swift apps/nano-ios/Sources/Model/AppSchema.swift apps/nano-ios/Sources/Model/LibraryStore.swift apps/nano-ios/Tests/FolderNodeTests.swift apps/nano-ios/NanoMeters.xcodeproj
git commit -m "feat(ios): FolderNode @Model + LibraryStore folder helpers

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Track gains sourceId / providerFileId / folderId

**Files:**
- Modify: `apps/nano-ios/Sources/Model/Track.swift`
- Test: `apps/nano-ios/Tests/SourceModelTests.swift` (extend)

Adding three OPTIONAL fields is an automatic lightweight SwiftData migration — existing on-device stores load unchanged with `nil` defaults.

- [ ] **Step 1: Write the failing test**

Append to `apps/nano-ios/Tests/SourceModelTests.swift`:
```swift
    func test_track_sourceRefs_defaultNil_andPersist() throws {
        let ctx = try TestDB.context()
        let t = Track(title: "A", artist: "", album: "")
        XCTAssertNil(t.sourceId)
        XCTAssertNil(t.folderId)
        XCTAssertNil(t.providerFileId)
        t.sourceId = "gdrive"; t.folderId = "house"; t.providerFileId = "drive-file-1"
        ctx.insert(t)
        let fetched = try LibraryStore.track(id: t.id, ctx)
        XCTAssertEqual(fetched?.sourceId, "gdrive")
        XCTAssertEqual(fetched?.folderId, "house")
        XCTAssertEqual(fetched?.providerFileId, "drive-file-1")
    }
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `value of type 'Track' has no member 'sourceId'`.

- [ ] **Step 3: Write minimal implementation**

In `apps/nano-ios/Sources/Model/Track.swift`, after the `displayPath` line (the source/location block), add the stored properties:
```swift
    // Folder-browser refs (Library & Sources). nil for pre-migration / unattached tracks.
    var sourceId: String?
    var providerFileId: String?   // cloud provider's file id (Drive fileId, etc.)
    var folderId: String?         // leaf FolderNode id; breadcrumb path walks parentId up
```
Add matching init parameters (defaulting nil) and assignments. Append to the `init` signature after `waveformCacheKey: String = ""`:
```swift
        sourceId: String? = nil,
        providerFileId: String? = nil,
        folderId: String? = nil
```
And in the body, after `self.waveformCacheKey = waveformCacheKey`:
```swift
        self.sourceId = sourceId
        self.providerFileId = providerFileId
        self.folderId = folderId
```

- [ ] **Step 4: Run tests to verify they pass**

Run (no new file, so no regen needed — but harmless to regen). Expected: new test PASSES, `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Model/Track.swift apps/nano-ios/Tests/SourceModelTests.swift
git commit -m "feat(ios): Track sourceId/providerFileId/folderId refs (optional)

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: SourcesMigration — seed the local source + attach existing tracks

**Files:**
- Create: `apps/nano-ios/Sources/Import/SourcesMigration.swift`
- Test: `apps/nano-ios/Tests/SourcesMigrationTests.swift`

Idempotent: if a `local` Source already exists, do nothing. Otherwise create the local Source (connected), one RootFolder ("On My iPhone"), one root FolderNode holding every existing local track, and stamp each track's `sourceId`/`folderId`.

- [ ] **Step 1: Write the failing test**

Create `apps/nano-ios/Tests/SourcesMigrationTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class SourcesMigrationTests: XCTestCase {
    func test_run_seedsLocalSource_andAttachesExistingTracks() throws {
        let ctx = try TestDB.context()
        let t1 = Track(title: "A", artist: "", album: "")
        let t2 = Track(title: "B", artist: "", album: "")
        [t1, t2].forEach(ctx.insert)

        SourcesMigration.runIfNeeded(ctx)

        let local = try LibraryStore.source(id: "local", ctx)
        XCTAssertEqual(local?.state, "connected")
        let roots = try LibraryStore.rootFolders(of: "local", ctx)
        XCTAssertEqual(roots.count, 1)
        // Every existing track is now attached to the local root node.
        let node = try LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx)
        XCTAssertEqual(Set(node?.trackIds ?? []), Set([t1.id, t2.id]))
        XCTAssertEqual(try LibraryStore.track(id: t1.id, ctx)?.sourceId, "local")
        XCTAssertEqual(try LibraryStore.track(id: t1.id, ctx)?.folderId, SourcesMigration.localRootNodeId)
    }

    func test_run_isIdempotent() throws {
        let ctx = try TestDB.context()
        ctx.insert(Track(title: "A", artist: "", album: ""))
        SourcesMigration.runIfNeeded(ctx)
        SourcesMigration.runIfNeeded(ctx)   // second run must not duplicate
        XCTAssertEqual(try LibraryStore.allSources(ctx).count, 1)
        XCTAssertEqual(try LibraryStore.rootFolders(of: "local", ctx).count, 1)
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `cannot find 'SourcesMigration' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `apps/nano-ios/Sources/Import/SourcesMigration.swift`:
```swift
import Foundation
import SwiftData

/// One-shot, idempotent data migration (handoff §11): pre-existing tracks predate the Source model, so
/// attach them to a seeded "On My iPhone" local source under a single synthetic root, keeping them
/// reachable in the new folder-browser Library. Runs at launch after `DemoSeed`.
enum SourcesMigration {
    /// Stable id of the synthetic local root FolderNode the migration creates; tracks link to it by id.
    static let localRootNodeId = "local-root"

    @MainActor
    static func runIfNeeded(_ ctx: ModelContext) {
        let existingLocal = (try? LibraryStore.source(id: "local", ctx)) ?? nil
        guard existingLocal == nil else { return }

        let source = Source(id: "local", kind: .local, state: .connected)
        ctx.insert(source)
        let root = RootFolder(sourceId: "local", name: SourceKind.local.label)
        ctx.insert(root)

        let existing = (try? LibraryStore.allTracks(ctx)) ?? []
        let localTracks = existing.filter { $0.sourceKind == SourceKind.local.rawValue || $0.sourceId == nil }
        for t in localTracks {
            t.sourceId = "local"
            t.folderId = localRootNodeId
        }
        let node = FolderNode(id: localRootNodeId, sourceId: "local",
                              name: SourceKind.local.label, parentId: nil,
                              childFolderIds: [], trackIds: localTracks.map(\.id),
                              lastIndexed: .init())
        ctx.insert(node)
    }
}
```
> The migration links the root node by the constant string `localRootNodeId` (`"local-root"`); the
> `RootFolder.id` UUID is generated normally. The `RootFolder` and the `FolderNode` are separate rows —
> the root folder's *browse node* is `localRootNodeId`; `LibraryIndex.rootNode(for:)` resolves a local
> root to its parentless node (it has no `providerFolderId`).

- [ ] **Step 4: Run tests to verify they pass**

Regenerate + run. Expected: 2 new tests PASS, `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Import/SourcesMigration.swift apps/nano-ios/Tests/SourcesMigrationTests.swift apps/nano-ios/NanoMeters.xcodeproj
git commit -m "feat(ios): SourcesMigration seeds local source + attaches existing tracks

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Run the migration at launch

**Files:**
- Modify: `apps/nano-ios/Sources/NanoMetersApp.swift`
- Test: `apps/nano-ios/Tests/SourcesMigrationTests.swift` (extend — simulate the launch sequence)

- [ ] **Step 1: Write the failing test**

Append to `apps/nano-ios/Tests/SourcesMigrationTests.swift`:
```swift
    func test_launchSequence_seedThenMigrate_attachesDemoTracks() throws {
        let ctx = try TestDB.context()
        DemoSeed.seedIfEmpty(ctx)            // first-run demo content
        SourcesMigration.runIfNeeded(ctx)    // then attach to local source

        let node = try LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx)
        let demoTitles = try LibraryStore.tracksInFolder(id: SourcesMigration.localRootNodeId, ctx).map(\.title)
        XCTAssertEqual(node?.sourceId, "local")
        XCTAssertEqual(Set(demoTitles), ["Biljam", "Mercy"])
    }
```

- [ ] **Step 2: Run test to verify it fails**

This test exercises code that already exists (Task 7) plus the launch ordering. It should PASS already at the unit level — run it to confirm the sequence works. If it passes, the wiring step (Step 3) is what makes it real at app launch. (If it fails, fix `SourcesMigration` before wiring.)

Run the test command filtered to the new test. Expected: PASS.

- [ ] **Step 3: Wire into app launch**

In `apps/nano-ios/Sources/NanoMetersApp.swift`, replace the seed line in `init()`:
```swift
        MainActor.assumeIsolated {
            DemoSeed.seedIfEmpty(container.mainContext)
            SourcesMigration.runIfNeeded(container.mainContext)
        }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the full bundle. Expected: all green, `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/NanoMetersApp.swift apps/nano-ios/Tests/SourcesMigrationTests.swift
git commit -m "feat(ios): run SourcesMigration after DemoSeed at launch

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: LibraryIndex — reachable set, recursive counts, trackId→path

**Files:**
- Create: `apps/nano-ios/Sources/Model/LibraryIndex.swift`
- Test: `apps/nano-ios/Tests/LibraryIndexTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/nano-ios/Tests/LibraryIndexTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibraryIndexTests: XCTestCase {
    /// Build: gdrive (connected) → root "My Productions" [house(2 tracks), dnb(1 track)]; local disconnected.
    private func fixture() throws -> (ModelContext, [String: Track]) {
        let ctx = try TestDB.context()
        ctx.insert(Source(id: "gdrive", kind: .gdrive, state: .connected))
        ctx.insert(Source(id: "local", kind: .local, state: .disconnected))
        ctx.insert(RootFolder(sourceId: "gdrive", name: "My Productions", providerFolderId: "mine"))
        ctx.insert(RootFolder(sourceId: "local", name: "Old", bookmark: Data([9])))

        var tracks: [String: Track] = [:]
        func mk(_ key: String, folder: String) -> UUID {
            let t = Track(title: key, artist: "", album: "")
            t.sourceId = "gdrive"; t.folderId = folder
            ctx.insert(t); tracks[key] = t; return t.id
        }
        ctx.insert(FolderNode(id: "mine", sourceId: "gdrive", name: "My Productions",
                              parentId: nil, childFolderIds: ["house", "dnb"]))
        let h1 = mk("h1", folder: "house"); let h2 = mk("h2", folder: "house")
        let d1 = mk("d1", folder: "dnb")
        ctx.insert(FolderNode(id: "house", sourceId: "gdrive", name: "House", parentId: "mine", trackIds: [h1, h2]))
        ctx.insert(FolderNode(id: "dnb", sourceId: "gdrive", name: "Drum & Bass", parentId: "mine", trackIds: [d1]))
        // A local track under the DISCONNECTED source — must NOT be reachable.
        let lt = Track(title: "old", artist: "", album: ""); lt.sourceId = "local"; lt.folderId = "old"
        ctx.insert(lt); tracks["old"] = lt
        ctx.insert(FolderNode(id: "old", sourceId: "local", name: "Old", parentId: nil, trackIds: [lt.id]))
        return (ctx, tracks)
    }

    func test_reachable_excludesDisconnectedSources() throws {
        let (ctx, t) = try fixture()
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertTrue(idx.reachableTrackIds.contains(t["h1"]!.id))
        XCTAssertFalse(idx.reachableTrackIds.contains(t["old"]!.id))   // disconnected source
        XCTAssertEqual(idx.reachableTrackIds.count, 3)
    }

    func test_recursiveCounts() throws {
        let (ctx, _) = try fixture()
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        XCTAssertEqual(idx.folderCounts["mine"]?.folders, 2)
        XCTAssertEqual(idx.folderCounts["mine"]?.tracks, 3)   // recursive
        XCTAssertEqual(idx.folderCounts["house"]?.tracks, 2)
        XCTAssertEqual(idx.sourceCounts["gdrive"]?.tracks, 3)
        XCTAssertEqual(idx.sourceCounts["gdrive"]?.folders, 3) // root + 2 children
    }

    func test_pathForGoToSource() throws {
        let (ctx, t) = try fixture()
        let idx = LibraryIndex(); idx.rebuild(from: ctx)
        let p = idx.trackPath[t["h1"]!.id]
        XCTAssertEqual(p?.sourceId, "gdrive")
        XCTAssertEqual(p?.folderIds, ["mine", "house"])   // root → leaf
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — `cannot find 'LibraryIndex' in scope`.

- [ ] **Step 3: Write minimal implementation**

Create `apps/nano-ios/Sources/Model/LibraryIndex.swift`:
```swift
import Foundation
import SwiftData
import Observation

/// The one place reachability, recursive counts, and trackId→path are derived (handoff §06). Rebuilt on
/// connect/disconnect/add-root/remove-root and after enumeration. Powers All Songs, source/folder
/// subtitles, scoped search, and Go-to-Source. A track is *reachable* only under a non-disconnected
/// source's added root.
@MainActor
@Observable
final class LibraryIndex {
    struct Counts: Equatable { var folders: Int = 0; var tracks: Int = 0 }

    private(set) var reachableTrackIds: Set<UUID> = []
    private(set) var sourceCounts: [String: Counts] = [:]
    private(set) var folderCounts: [String: Counts] = [:]
    private(set) var trackPath: [UUID: (sourceId: String, folderIds: [String])] = [:]

    func rebuild(from ctx: ModelContext) {
        var reachable: Set<UUID> = []
        var sCounts: [String: Counts] = [:]
        var fCounts: [String: Counts] = [:]
        var paths: [UUID: (String, [String])] = [:]

        let sources = (try? LibraryStore.allSources(ctx)) ?? []
        let allNodes = (try? ctx.fetch(FetchDescriptor<FolderNode>())) ?? []
        let nodesById = Dictionary(uniqueKeysWithValues: allNodes.map { ($0.id, $0) })

        for source in sources where SourceState(rawValue: source.state) != .disconnected {
            let roots = (try? LibraryStore.rootFolders(of: source.id, ctx)) ?? []
            var srcCount = Counts()
            for root in roots {
                guard let rootNode = rootNode(for: root, in: nodesById) else { continue }
                let c = walk(rootNode, source: source.id, prefix: [],
                             nodesById: nodesById,
                             reachable: &reachable, fCounts: &fCounts, paths: &paths)
                srcCount.folders += c.folders
                srcCount.tracks += c.tracks
            }
            sCounts[source.id] = srcCount
        }
        reachableTrackIds = reachable
        sourceCounts = sCounts
        folderCounts = fCounts
        trackPath = paths.reduce(into: [:]) { $0[$1.key] = ($1.value.0, $1.value.1) }
    }

    /// A root's FolderNode: cloud roots match by `providerFolderId`; local roots use the migration's
    /// derived node id. Falls back to any node whose id equals the root's providerFolderId.
    private func rootNode(for root: RootFolder, in nodesById: [String: FolderNode]) -> FolderNode? {
        if let pid = root.providerFolderId, let n = nodesById[pid] { return n }
        // Local root: the migration created a node id "local-root" (no providerFolderId).
        return nodesById.values.first { $0.sourceId == root.sourceId && $0.parentId == nil }
    }

    /// Depth-first accumulate: counts this node as one folder, adds its direct tracks, recurses children.
    private func walk(_ node: FolderNode, source: String, prefix: [String],
                      nodesById: [String: FolderNode],
                      reachable: inout Set<UUID>, fCounts: inout [String: Counts],
                      paths: inout [UUID: (String, [String])]) -> Counts {
        let here = prefix + [node.id]
        var folders = 1
        var tracks = node.trackIds.count
        for tid in node.trackIds {
            reachable.insert(tid)
            paths[tid] = (source, here)
        }
        for childId in node.childFolderIds {
            guard let child = nodesById[childId] else { continue }
            let c = walk(child, source: source, prefix: here, nodesById: nodesById,
                         reachable: &reachable, fCounts: &fCounts, paths: &paths)
            folders += c.folders
            tracks += c.tracks
        }
        fCounts[node.id] = Counts(folders: folders - 1, tracks: tracks)  // exclude self from folder count
        return Counts(folders: folders, tracks: tracks)
    }
}
```
> **Note on counts semantics (verify against the test):** `folderCounts[id].folders` is the number of
> *descendant* folders (excludes the node itself), while the source total counts every folder in the
> subtree including roots — that's why `sourceCounts["gdrive"].folders == 3` (mine + house + dnb) but
> `folderCounts["mine"].folders == 2` (house + dnb). The `walk` return value includes self (so the
> parent sums correctly); the value *stored* in `fCounts` subtracts self.

- [ ] **Step 4: Run tests to verify they pass**

Regenerate + run. Expected: 3 LibraryIndex tests PASS, `TEST SUCCEEDED`. If `sourceCounts.folders` is off by the root, re-check the self-vs-descendant note above and adjust so the three assertions hold.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Model/LibraryIndex.swift apps/nano-ios/Tests/LibraryIndexTests.swift apps/nano-ios/NanoMeters.xcodeproj
git commit -m "feat(ios): LibraryIndex — reachable set, recursive counts, track paths

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Imported local files land under the local source

**Files:**
- Modify: `apps/nano-ios/Sources/Import/TrackImporter.swift`
- Test: `apps/nano-ios/Tests/ImportTests.swift` (extend — assert attachment)

So newly imported local files are reachable (in All Songs / counts), they must be stamped with the local source and appended to the local root node created by the migration.

- [ ] **Step 1: Write the failing test**

First inspect `apps/nano-ios/Tests/ImportTests.swift` for the existing import-test pattern (how it builds a temp file + context). Then append a test that imports one temp audio file into a context where the migration has run, and asserts the resulting track is attached:
```swift
    func test_import_attachesTrackToLocalRootNode() async throws {
        let ctx = try TestDB.context()
        SourcesMigration.runIfNeeded(ctx)   // creates the local source + root node

        // Reuse the existing helper this file uses to produce a temp file URL; if it is named
        // differently, match it. Here we assume `makeTempAudioURL()` exists in this test file.
        let url = try makeTempAudioURL()
        _ = await TrackImporter.importFiles([url], into: ctx)

        let node = try LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx)
        XCTAssertEqual(node?.trackIds.count, 1)
        let imported = try LibraryStore.allTracks(ctx).first { $0.sourceId == "local" && $0.bundledName == nil }
        XCTAssertEqual(imported?.folderId, SourcesMigration.localRootNodeId)
        XCTAssertTrue(node?.trackIds.contains(imported!.id) ?? false)
    }
```
> If `ImportTests.swift` has no temp-file helper, add a minimal one in the test file:
> ```swift
> private func makeTempAudioURL() throws -> URL {
>     let url = FileManager.default.temporaryDirectory.appendingPathComponent("imp-\(UUID()).wav")
>     try Data([0x52,0x49,0x46,0x46]).write(to: url)   // not real audio; importer falls back to filename
>     return url
> }
> ```

- [ ] **Step 2: Run test to verify it fails**

Expected: FAIL — the imported track has `sourceId == nil` / the local root node still has 0 tracks.

- [ ] **Step 3: Write minimal implementation**

In `apps/nano-ios/Sources/Import/TrackImporter.swift`, after `ctx.insert(track)` (and before the `WaveformStore` kick), attach the track to the local source's root node:
```swift
            ctx.insert(track)
            attachToLocalRoot(track, in: ctx)
```
Add the helper to the enum:
```swift
    /// Stamp the local source ref and append to the migration's local root node so the track is
    /// reachable (All Songs / counts) the moment it appears.
    @MainActor
    private static func attachToLocalRoot(_ track: Track, in ctx: ModelContext) {
        track.sourceId = "local"
        track.folderId = SourcesMigration.localRootNodeId
        if let node = try? LibraryStore.folderNode(id: SourcesMigration.localRootNodeId, ctx) {
            node.trackIds.append(track.id)
        }
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run the full bundle. Expected: new test PASSES; all prior tests still green; `TEST SUCCEEDED`.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Import/TrackImporter.swift apps/nano-ios/Tests/ImportTests.swift
git commit -m "feat(ios): imported files attach to the local source root node

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Phase 1 acceptance

- [ ] `Source` / `RootFolder` / `FolderNode` persist; `Track` carries `sourceId`/`providerFileId`/`folderId`.
- [ ] Launch seeds an "On My iPhone" source with one root holding the demo + imported tracks; idempotent.
- [ ] `LibraryIndex` computes reachable set (excludes disconnected sources), recursive counts, and
      root→leaf paths — verified against a multi-level fixture.
- [ ] All prior tests still pass; the app still renders the existing flat list (no UI change yet).
- [ ] Full bundle green on iPhone 16 Pro (Nano).

**Next phase:** Phase 2 — `LibraryNav` + the folder-browser UI rendering from `LibraryIndex` (its own plan).
```
