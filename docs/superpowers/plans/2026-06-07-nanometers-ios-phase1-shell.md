# Nanometers iOS — Phase 1: App Shell Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A runnable SwiftUI iOS app shell at `apps/nano-ios` — the four tab surfaces (Library · Playlists · Search) over a custom glass tab bar, backed by a SwiftData library you can populate via the document picker (plus a first-run demo seed) — with **no playback, no DSP, no waveforms yet** (Phases 2–3).

**Architecture:** A SwiftData store (`Track`, `Playlist`) is the single source of truth. `RootView` drives tab selection with a plain `@State` enum and overlays the custom glass tab bar (no system `UITabBar`). Each tab is a `NavigationStack` rendering library data through one reusable `NMRow`. Import resolves files via `.fileImporter` + security-scoped bookmarks. Look/spacing come verbatim from the design handoff tokens (`Theme`). The Rust `NanoDSP.xcframework` is **not** linked yet — it arrives in Phase 3 when waveforms/LUFS appear.

**Tech Stack:** Swift 5.10 / SwiftUI / SwiftData (iOS 17+), AVFoundation (metadata read only), UniformTypeIdentifiers, XcodeGen (project generation), XCTest + `xcodebuild` (iPhone simulator).

**Branch:** `worktree-nano-ios` (now at `main` after Phase 0). Work in this git worktree.

**Source of truth for look & behavior:** the locked handoff at `~/Downloads/design_handoff_nanometers/` — `01-design-tokens.md` (tokens), `02-components.md` (NMArtwork, NMRow, glass tab bar), `03-screens.md` (Library/Playlists/Detail/Search), `04-data-and-sources.md` (SwiftData models, import, bookmarks), and the 4 `.heic` reference screenshots. **Do not restate token values in code comments — pull them from `Theme` and cite the handoff section.**

**Verify against the handoff after every task.** Each task below ends with a *Verify against the handoff* step naming the exact file/section — and, for visible surfaces, the reference screenshot — to check the result against. The handoff is canonical: **do not mark a task done until its output matches it.** The four screenshots are `Library view.heic`, `Library view with collapsed player.heic`, `Playlist view.heic`, and `Search view.heic`. To view a `.heic` on macOS during verification: `qlmanage -p "~/Downloads/design_handoff_nanometers/Library view.heic"` (Quick Look) or open it in Preview. (Task 1 is pure scaffolding with no visible surface, so its check is just the build/test gate.)

---

## Decisions (resolve the spec's open Phase-1 questions)

1. **XcodeGen, not a hand-rolled `.xcodeproj`.** A committed `apps/nano-ios/project.yml` declares the app + test targets; `xcodegen generate` produces the `.xcodeproj` (gitignored). Reviewable, reproducible, no `.pbxproj` merge pain. Prereq: `brew install xcodegen`. *(Alternative if you object: commit a generated `.xcodeproj` once — but then every target change is a binary-ish diff.)*
2. **iPhone, portrait, iOS 17.0+** (`TARGETED_DEVICE_FAMILY = 1`, portrait-only). No iPad, per the spec's out-of-scope.
3. **No DSP / xcframework link in Phase 1.** The shell needs no Rust. `NanoDSP.xcframework` is wired in Phase 3.
4. **Playlist ordering = an explicit `[UUID]` array** on `Playlist` (`itemIDs`), resolved against `Track` rows (per handoff §04 — SwiftData relationships aren't reliably ordered). No join model.
5. **Demo seed for first run** = a few `Track` rows inserted programmatically (metadata only, **no playable file**, two intentionally art-less to exercise the fallback). Playback isn't in this phase, so demo rows need no audio. Real files come via import.
6. **Deferred to later phases, stubbed here:** tapping a row does **not** play (Phase 2 wires `AudioEngine`); `NMRow`'s mini-waveform and per-track LUFS slots render **nothing** yet (Phase 3); the `MiniPlayer`, `NowPlaying`, and `Settings`/`Sources` sheets are absent (Phases 2/4 / v2). The Library header's "Sources" stat tile points at the Playlists tab for now (the Sources hub is v2).
7. **Testing:** XCTest unit tests (model logic, search filter, playlist ordering, demo seed, bookmark round-trip) run via `xcodebuild test` on an iPhone simulator; a `xcodebuild build` smoke; and a manual visual check against the 4 reference screenshots. TDD the logic units; SwiftUI layout is build-and-eyeball.

---

## File Structure

```
apps/nano-ios/
├── project.yml                         XcodeGen spec (app + test targets)
├── .gitignore                          NanoMeters.xcodeproj/, build artifacts
├── Sources/
│   ├── Info.plist                      orientation (portrait), launch screen
│   ├── NanoMetersApp.swift             @main App; installs the ModelContainer; first-run seed
│   ├── RootView.swift                  tab-selection enum + content switch + glass tab bar overlay
│   ├── Theme/
│   │   └── Theme.swift                 Color + Font tokens (handoff §01); materials; radii
│   ├── Model/
│   │   ├── Track.swift                 @Model (handoff §04)
│   │   ├── Playlist.swift              @Model (handoff §04); [UUID] ordering
│   │   ├── SourceKind.swift            enum (field today; cloud is v2)
│   │   └── LibraryStore.swift          fetch helpers + playlist mutation (ordered)
│   ├── Import/
│   │   ├── TrackImporter.swift         .fileImporter URLs → metadata + bookmark → Track
│   │   └── DemoSeed.swift              first-run sample Tracks
│   ├── Components/
│   │   ├── NMArtwork.swift             embedded art / glyph fallback tile
│   │   ├── NMRow.swift                 track row (artwork + title/artist + ellipsis; wave/LUFS stubbed)
│   │   ├── PlaylistCover.swift         2×2 mosaic
│   │   ├── GlassTabBar.swift           custom floating pill bar
│   │   └── GlassRoundButton.swift      header circular buttons
│   └── Screens/
│       ├── LibraryScreen.swift         header + stat tiles + Songs list
│       ├── PlaylistsScreen.swift       list + New Playlist
│       ├── NewPlaylistSheet.swift      name + track selection
│       ├── PlaylistDetailScreen.swift  header + tracks + add/reorder/delete
│       └── SearchScreen.swift          field + filtered list
└── Tests/
    ├── LibraryStoreTests.swift         insert/fetch, playlist order, mutation
    ├── SearchTests.swift               filter by title/artist/album
    ├── DemoSeedTests.swift             first-run idempotence + art-less rows
    └── ImportTests.swift              bookmark round-trip (temp file)
```

---

## Task 1: Scaffold the XcodeGen project + a launchable shell

**Files:**
- Create: `apps/nano-ios/project.yml`, `apps/nano-ios/.gitignore`, `apps/nano-ios/Sources/Info.plist`, `apps/nano-ios/Sources/NanoMetersApp.swift`, `apps/nano-ios/Sources/RootView.swift`, `apps/nano-ios/Tests/SmokeTests.swift`

- [ ] **Step 1: Write the XcodeGen spec**

Create `apps/nano-ios/project.yml`:
```yaml
name: NanoMeters
options:
  bundleIdPrefix: com.willeasp.nanometers
  deploymentTarget: { iOS: "17.0" }
  createIntermediateGroups: true
settings:
  base:
    SWIFT_VERSION: "5.10"
    MARKETING_VERSION: "0.1.0"
    CURRENT_PROJECT_VERSION: "1"
    TARGETED_DEVICE_FAMILY: "1"          # iPhone only
    CODE_SIGNING_ALLOWED: "NO"           # simulator builds/tests need no signing
targets:
  NanoMeters:
    type: application
    platform: iOS
    sources: [Sources]
    info:
      path: Sources/Info.plist
      properties:
        CFBundleDisplayName: NanoMeters
        UILaunchScreen: {}
        UISupportedInterfaceOrientations: [UIInterfaceOrientationPortrait]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.willeasp.nanometers.ios
  NanoMetersTests:
    type: bundle.unit-test
    platform: iOS
    sources: [Tests]
    dependencies:
      - target: NanoMeters
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.willeasp.nanometers.ios.tests
schemes:
  NanoMeters:
    build:
      targets: { NanoMeters: all, NanoMetersTests: [test] }
    test:
      targets: [NanoMetersTests]
```

- [ ] **Step 2: Gitignore the generated project**

Create `apps/nano-ios/.gitignore`:
```gitignore
NanoMeters.xcodeproj/
build/
DerivedData/
*.xcuserstate
```

- [ ] **Step 3: Minimal Info.plist**

Create `apps/nano-ios/Sources/Info.plist`:
```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
</dict>
</plist>
```
(XcodeGen merges the `info.properties` from `project.yml` into this at generate time.)

- [ ] **Step 4: App entry + a placeholder RootView**

Create `apps/nano-ios/Sources/NanoMetersApp.swift`:
```swift
import SwiftUI

@main
struct NanoMetersApp: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
    }
}
```
Create `apps/nano-ios/Sources/RootView.swift` (placeholder — fleshed out in Task 6):
```swift
import SwiftUI

struct RootView: View {
    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            Text("NanoMeters")
                .foregroundStyle(.white)
        }
    }
}

#Preview { RootView() }
```

- [ ] **Step 5: A smoke test so the test target has a source**

Create `apps/nano-ios/Tests/SmokeTests.swift`:
```swift
import XCTest

final class SmokeTests: XCTestCase {
    func test_targetLinks() {
        XCTAssertTrue(true)
    }
}
```

- [ ] **Step 6: Generate, build, and test on a simulator**

Run (install XcodeGen first if missing: `brew install xcodegen`):
```bash
cd apps/nano-ios && xcodegen generate
SIM=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone 1[0-9]( Pro)?' | head -1)
echo "using simulator: $SIM"
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination "platform=iOS Simulator,name=$SIM" build
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination "platform=iOS Simulator,name=$SIM" test
cd ../..
```
Expected: `** BUILD SUCCEEDED **` and `** TEST SUCCEEDED **` (1 test). If no `iPhone 1x` simulator is listed, pick any available iOS device from `xcrun simctl list devices available` and use its exact name.

- [ ] **Step 7: Commit**

```bash
git add apps/nano-ios/project.yml apps/nano-ios/.gitignore apps/nano-ios/Sources apps/nano-ios/Tests
git commit -m "feat(ios): scaffold the NanoMeters app shell (XcodeGen, iOS 17, portrait)

XcodeGen project.yml for the app + unit-test targets; @main App entry + a
placeholder RootView; a smoke test. Builds and tests on the iPhone simulator.
The .xcodeproj is generated, not committed.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 2: Theme — design tokens from handoff §01

**Files:**
- Create: `apps/nano-ios/Sources/Theme/Theme.swift`
- Test: `apps/nano-ios/Tests/ThemeTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/nano-ios/Tests/ThemeTests.swift`:
```swift
import XCTest
import SwiftUI
@testable import NanoMeters

final class ThemeTests: XCTestCase {
    func test_accentHexParses() {
        // The locked accent is #EFA869 (handoff §01). A round-trip through the hex initializer
        // must reproduce those 8-bit channels.
        let c = UIColor(Theme.accent).cgColor.components!
        XCTAssertEqual(c[0], 0xEF / 255, accuracy: 0.01)
        XCTAssertEqual(c[1], 0xA8 / 255, accuracy: 0.01)
        XCTAssertEqual(c[2], 0x69 / 255, accuracy: 0.01)
    }
}
```

- [ ] **Step 2: Run it — fails to compile (`Theme` undefined)**

Run: `cd apps/nano-ios && xcodegen generate && xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters -destination "platform=iOS Simulator,name=$SIM" test`
Expected: FAIL — `cannot find 'Theme' in scope`.

- [ ] **Step 3: Implement Theme**

Create `apps/nano-ios/Sources/Theme/Theme.swift`. Values are transcribed once here from handoff §01 — everything else references `Theme`, never re-states them:
```swift
import SwiftUI

/// Design tokens, transcribed once from the handoff (`01-design-tokens.md`). Views read these —
/// they never hard-code hexes or sizes. Keep this file the single mirror of §01.
enum Theme {
    // Surfaces
    static let bg      = Color(hex: 0x15171E)
    static let bgElev  = Color(hex: 0x1C1F28)
    static let bgElev2 = Color(hex: 0x232732)
    // Text
    static let text  = Color(hex: 0xF3F4F7)
    static let text2 = Color(hex: 0x9AA1B0)
    static let text3 = Color(hex: 0x626A78)
    // Accent (locked)
    static let accent = Color(hex: 0xEFA869)
    // Frequency bands (handoff §01) — used by the waveforms in Phase 3; defined now for completeness.
    static let bandBass   = Color(hex: 0xFF6B6B)
    static let bandMid    = Color(hex: 0x57D986)
    static let bandTreble = Color(hex: 0x6AA6FF)
    static let bandMix    = Color(hex: 0xEEF1F6)
    // Hairlines / glass
    static let hair        = Color.white.opacity(0.08)
    static let glassBorder = Color.white.opacity(0.10)
    static let glassSheen  = Color.white.opacity(0.14)
    static let artFallback = Color(hex: 0x22252E)

    // Corner radii (§01)
    enum Radius {
        static let albumRow: CGFloat = 7
        static let statTile: CGFloat = 16
        static let tabBar: CGFloat = 30
        static let searchField: CGFloat = 12
        static let mosaic: CGFloat = 12
        static let button: CGFloat = 14
    }

    // Layout (§01)
    enum Layout {
        static let screenMargin: CGFloat = 20
        static let rowMinHeight: CGFloat = 56
        static let rowSeparatorInset: CGFloat = 78   // after 46pt artwork + gaps
        static let scrollBottomPadding: CGFloat = 100 // no-mini case; ~168 once the mini player exists (Phase 2)
    }

    // Fonts — SF Pro for text, SF Mono for ALL numerics (.monospacedDigit), §01.
    static func sans(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }
    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    /// 0xRRGGBB literal → Color (sRGB). Used only inside `Theme`.
    init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1
        )
    }
}
```

- [ ] **Step 4: Run the test → passes**

Run the same `xcodebuild ... test`. Expected: PASS (`ThemeTests` + smoke).

- [ ] **Step 5: Verify against the handoff (`01-design-tokens.md`)**

Open `01-design-tokens.md` side by side and cross-check **every** `Theme` constant — §01 is canonical, a mismatch is a bug:
- Surfaces `bg`/`bgElev`/`bgElev2` = `#15171E`/`#1C1F28`/`#232732`; text `#F3F4F7`/`#9AA1B0`/`#626A78`; **accent `#EFA869`**; the four band hexes; `hair` white@8%, `glassBorder` white@10%, sheen white@14%.
- Radii table (album row 7, stat tile 16, tab bar 30, search 12, mosaic 12, button 14); spacing (screen margin 20, row min 56, separator inset ~78); SF Pro + SF Mono (`.monospacedDigit()` for numerics).
Fix any divergence in `Theme.swift` before committing.

- [ ] **Step 6: Commit**

```bash
git add apps/nano-ios/Sources/Theme apps/nano-ios/Tests/ThemeTests.swift
git commit -m "feat(ios): Theme — design tokens from handoff §01

Single mirror of the locked tokens (colors, radii, layout, SF Pro/Mono). Views
read Theme; they never re-state hexes or sizes. Accent round-trip is tested.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 3: SwiftData models — Track, Playlist, SourceKind, LibraryStore

**Files:**
- Create: `apps/nano-ios/Sources/Model/Track.swift`, `Playlist.swift`, `SourceKind.swift`, `LibraryStore.swift`
- Modify: `apps/nano-ios/Sources/NanoMetersApp.swift` (install the container)
- Test: `apps/nano-ios/Tests/LibraryStoreTests.swift`

- [ ] **Step 1: Write the failing test**

Create `apps/nano-ios/Tests/LibraryStoreTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class LibraryStoreTests: XCTestCase {
    private func makeContext() throws -> ModelContext {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        return ModelContext(container)
    }

    func test_insertAndFetchTracks() throws {
        let ctx = try makeContext()
        ctx.insert(Track(title: "A", artist: "X", album: "Z"))
        ctx.insert(Track(title: "B", artist: "Y", album: "Z"))
        let all = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(all.count, 2)
    }

    func test_playlistKeepsExplicitOrder() throws {
        let ctx = try makeContext()
        let t1 = Track(title: "One", artist: "", album: "")
        let t2 = Track(title: "Two", artist: "", album: "")
        let t3 = Track(title: "Three", artist: "", album: "")
        [t1, t2, t3].forEach(ctx.insert)
        let pl = Playlist(name: "Mix")
        ctx.insert(pl)
        LibraryStore.append(t3, to: pl)   // deliberately out of insertion order
        LibraryStore.append(t1, to: pl)
        LibraryStore.append(t2, to: pl)
        let ordered = try LibraryStore.tracks(in: pl, ctx)
        XCTAssertEqual(ordered.map(\.title), ["Three", "One", "Two"])
    }

    func test_moveAndRemovePreserveOrder() throws {
        let ctx = try makeContext()
        let ts = (0..<4).map { Track(title: "\($0)", artist: "", album: "") }
        ts.forEach(ctx.insert)
        let pl = Playlist(name: "Q"); ctx.insert(pl)
        ts.forEach { LibraryStore.append($0, to: pl) }
        LibraryStore.move(in: pl, fromOffsets: IndexSet(integer: 0), toOffset: 4) // 0 -> end
        LibraryStore.remove(in: pl, atOffsets: IndexSet(integer: 0))              // drop new first ("1")
        let ordered = try LibraryStore.tracks(in: pl, ctx)
        XCTAssertEqual(ordered.map(\.title), ["2", "3", "0"])
    }
}
```

- [ ] **Step 2: Run it → fails to compile (`Track`/`Playlist`/`LibraryStore` undefined)**

Run the `xcodebuild ... test`. Expected: FAIL — unresolved identifiers.

- [ ] **Step 3: Implement the models**

Create `apps/nano-ios/Sources/Model/SourceKind.swift`:
```swift
import Foundation

/// Where a track's file lives. Only `.local` is exercised in Phase 1; cloud providers are a v2 cut
/// (handoff §04). Stored as the raw string on `Track.sourceKind`.
enum SourceKind: String, CaseIterable {
    case local, icloud, gdrive, onedrive, dropbox
    var label: String {
        switch self {
        case .local: "On My iPhone"
        case .icloud: "iCloud Drive"
        case .gdrive: "Google Drive"
        case .onedrive: "OneDrive"
        case .dropbox: "Dropbox"
        }
    }
}
```

Create `apps/nano-ios/Sources/Model/Track.swift` (fields per handoff §04; the DSP-derived ones are optional and stay nil until later phases):
```swift
import Foundation
import SwiftData

@Model
final class Track {
    @Attribute(.unique) var id: UUID
    var title: String
    var artist: String
    var album: String

    // Source / location (handoff §04). `bookmark` is nil for the demo seed (no file).
    var sourceKind: String
    var bookmark: Data?
    var folderBookmark: Data?
    var displayPath: String

    // Audio metadata, read once on import.
    var durationSec: Double
    var format: String
    var sampleRate: String
    var hasEmbeddedArt: Bool
    var artworkData: Data?        // small embedded artwork, if any
    var artworkTintHex: String?   // computed in Phase 4 (Now Playing gradient)

    // Loudness — the integrated value is analyzed in Phase 3; nil until then.
    var integratedLUFS: Double?

    // User state
    var isLoved: Bool
    var dateAdded: Date

    // Waveform cache pointer (Phase 3).
    var waveformCacheKey: String

    init(
        id: UUID = UUID(),
        title: String,
        artist: String,
        album: String,
        sourceKind: String = SourceKind.local.rawValue,
        bookmark: Data? = nil,
        folderBookmark: Data? = nil,
        displayPath: String = "On My iPhone",
        durationSec: Double = 0,
        format: String = "",
        sampleRate: String = "",
        hasEmbeddedArt: Bool = false,
        artworkData: Data? = nil,
        integratedLUFS: Double? = nil,
        isLoved: Bool = false,
        dateAdded: Date = .init(),
        waveformCacheKey: String = ""
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.sourceKind = sourceKind
        self.bookmark = bookmark
        self.folderBookmark = folderBookmark
        self.displayPath = displayPath
        self.durationSec = durationSec
        self.format = format
        self.sampleRate = sampleRate
        self.hasEmbeddedArt = hasEmbeddedArt
        self.artworkData = artworkData
        self.artworkTintHex = nil
        self.integratedLUFS = integratedLUFS
        self.isLoved = isLoved
        self.dateAdded = dateAdded
        self.waveformCacheKey = waveformCacheKey
    }
}
```

Create `apps/nano-ios/Sources/Model/Playlist.swift` (explicit ordering via `itemIDs`, handoff §04):
```swift
import Foundation
import SwiftData

@Model
final class Playlist {
    @Attribute(.unique) var id: UUID
    var name: String
    var subtitle: String
    var dateCreated: Date
    /// Ordered membership by Track id. SwiftData relationships aren't reliably ordered (handoff §04),
    /// so order lives here and is resolved against the Track store.
    var itemIDs: [UUID]
    var coverOverrideTrackID: UUID?

    init(
        id: UUID = UUID(),
        name: String,
        subtitle: String = "",
        dateCreated: Date = .init(),
        itemIDs: [UUID] = [],
        coverOverrideTrackID: UUID? = nil
    ) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.dateCreated = dateCreated
        self.itemIDs = itemIDs
        self.coverOverrideTrackID = coverOverrideTrackID
    }
}
```

Create `apps/nano-ios/Sources/Model/LibraryStore.swift` (fetch + ordered mutation helpers; no UI):
```swift
import Foundation
import SwiftData

/// Stateless query/mutation helpers over the SwiftData context. Keeps ordering logic (which lives in
/// `Playlist.itemIDs`) in one tested place, out of the views.
enum LibraryStore {
    static func allTracks(_ ctx: ModelContext) throws -> [Track] {
        try ctx.fetch(FetchDescriptor<Track>(sortBy: [SortDescriptor(\.dateAdded, order: .reverse)]))
    }

    static func track(id: UUID, _ ctx: ModelContext) throws -> Track? {
        var d = FetchDescriptor<Track>(predicate: #Predicate { $0.id == id })
        d.fetchLimit = 1
        return try ctx.fetch(d).first
    }

    static func allPlaylists(_ ctx: ModelContext) throws -> [Playlist] {
        try ctx.fetch(FetchDescriptor<Playlist>(sortBy: [SortDescriptor(\.dateCreated, order: .reverse)]))
    }

    /// Resolve a playlist's ordered tracks, skipping any dangling ids.
    static func tracks(in pl: Playlist, _ ctx: ModelContext) throws -> [Track] {
        let byID = Dictionary(uniqueKeysWithValues: try allTracks(ctx).map { ($0.id, $0) })
        return pl.itemIDs.compactMap { byID[$0] }
    }

    static func append(_ track: Track, to pl: Playlist) {
        guard !pl.itemIDs.contains(track.id) else { return }
        pl.itemIDs.append(track.id)
    }

    static func move(in pl: Playlist, fromOffsets: IndexSet, toOffset: Int) {
        pl.itemIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    static func remove(in pl: Playlist, atOffsets: IndexSet) {
        pl.itemIDs.remove(atOffsets: atOffsets)
    }
}
```

- [ ] **Step 4: Install the container in the app**

Replace `apps/nano-ios/Sources/NanoMetersApp.swift` with:
```swift
import SwiftUI
import SwiftData

@main
struct NanoMetersApp: App {
    let container: ModelContainer

    init() {
        do {
            container = try ModelContainer(for: Track.self, Playlist.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(container)
    }
}
```

- [ ] **Step 5: Run the tests → pass**

Run `xcodebuild ... test`. Expected: PASS (`LibraryStoreTests` 3 + earlier). Then `xcodebuild ... build` to confirm the app target compiles with the container.

- [ ] **Step 6: Verify against the handoff (`04-data-and-sources.md`)**

Compare the models to the `@Model` definitions in `04-data-and-sources.md`: `Track` carries the §04 field set (id, title, artist, album, sourceKind, bookmark, folderBookmark, displayPath, durationSec, format, sampleRate, hasEmbeddedArt, artworkTintHex, integratedLUFS, isLoved, dateAdded, waveformCacheKey); `Playlist` carries name / subtitle / dateCreated / ordered items / coverOverrideTrackID. Confirm ordering uses the explicit `[UUID]` array §04 prescribes (not a SwiftData relationship). DSP-derived fields (integratedLUFS, waveformCacheKey, artworkTintHex) may be nil/empty now — Phases 3–4 fill them.

- [ ] **Step 7: Commit**

```bash
git add apps/nano-ios/Sources/Model apps/nano-ios/Sources/NanoMetersApp.swift apps/nano-ios/Tests/LibraryStoreTests.swift
git commit -m "feat(ios): SwiftData models — Track, Playlist, LibraryStore (handoff §04)

Track/Playlist @Model types with the §04 field set; playlist order is an
explicit [UUID] array resolved by LibraryStore (relationships aren't reliably
ordered). Container installed on the app. Insert/fetch/order/move/remove tested.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 4: Import — TrackImporter (bookmarks + metadata) and DemoSeed

**Files:**
- Create: `apps/nano-ios/Sources/Import/TrackImporter.swift`, `apps/nano-ios/Sources/Import/DemoSeed.swift`
- Test: `apps/nano-ios/Tests/ImportTests.swift`, `apps/nano-ios/Tests/DemoSeedTests.swift`

- [ ] **Step 1: Write the failing tests**

Create `apps/nano-ios/Tests/ImportTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class ImportTests: XCTestCase {
    func test_importCreatesTrackFromAFile() async throws {
        // Write a tiny temp .wav-named file (metadata extraction is best-effort; the import must
        // still produce a Track with a resolvable bookmark and a sensible title fallback).
        let dir = FileManager.default.temporaryDirectory
        let url = dir.appendingPathComponent("My_Bounce.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: url) // "RIFF" — enough to exist
        defer { try? FileManager.default.removeItem(at: url) }

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)

        let imported = await TrackImporter.importFiles([url], into: ctx)
        XCTAssertEqual(imported, 1)
        let tracks = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(tracks.count, 1)
        let t = tracks[0]
        XCTAssertFalse(t.title.isEmpty)               // filename fallback at least
        XCTAssertEqual(t.sourceKind, SourceKind.local.rawValue)
        XCTAssertNotNil(t.bookmark)                    // bookmark stored
        // The stored bookmark resolves back to a URL.
        var stale = false
        let resolved = try URL(resolvingBookmarkData: t.bookmark!, bookmarkDataIsStale: &stale)
        XCTAssertEqual(resolved.lastPathComponent, "My_Bounce.wav")
    }
}
```

Create `apps/nano-ios/Tests/DemoSeedTests.swift`:
```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class DemoSeedTests: XCTestCase {
    func test_seedsOnceAndIncludesArtlessRows() throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)

        DemoSeed.seedIfEmpty(ctx)
        let first = try LibraryStore.allTracks(ctx).count
        XCTAssertGreaterThan(first, 0)
        XCTAssertTrue(try LibraryStore.allTracks(ctx).contains { !$0.hasEmbeddedArt },
                      "at least one demo track is art-less to exercise the fallback")

        DemoSeed.seedIfEmpty(ctx)   // idempotent — must not duplicate
        XCTAssertEqual(try LibraryStore.allTracks(ctx).count, first)
    }
}
```

- [ ] **Step 2: Run → fails (`TrackImporter`/`DemoSeed` undefined)**

Run `xcodebuild ... test`. Expected: FAIL — unresolved identifiers.

- [ ] **Step 3: Implement TrackImporter**

Create `apps/nano-ios/Sources/Import/TrackImporter.swift`:
```swift
import Foundation
import SwiftData
import AVFoundation
import UniformTypeIdentifiers

/// Turns picked file URLs into `Track` rows: resolves a security-scoped bookmark, reads best-effort
/// metadata (title/artist/album/duration/artwork), and inserts. Handoff §04 (bookmarks) / §02
/// (artwork). Cloud availability + folder bookmarks are a v2 concern; we store what we can now.
enum TrackImporter {
    /// Returns the number of tracks imported.
    @MainActor
    static func importFiles(_ urls: [URL], into ctx: ModelContext) async -> Int {
        var count = 0
        for url in urls {
            let needsScope = url.startAccessingSecurityScopedResource()
            defer { if needsScope { url.stopAccessingSecurityScopedResource() } }

            let bookmark = try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
            let folderBookmark = try? url.deletingLastPathComponent()
                .bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)

            let meta = await readMetadata(url)
            let track = Track(
                title: meta.title,
                artist: meta.artist,
                album: meta.album,
                sourceKind: SourceKind.local.rawValue,
                bookmark: bookmark,
                folderBookmark: folderBookmark,
                displayPath: SourceKind.local.label,
                durationSec: meta.duration,
                format: url.pathExtension.uppercased(),
                sampleRate: "",
                hasEmbeddedArt: meta.artwork != nil,
                artworkData: meta.artwork
            )
            ctx.insert(track)
            count += 1
        }
        return count
    }

    private struct Meta { var title: String; var artist: String; var album: String; var duration: Double; var artwork: Data? }

    private static func readMetadata(_ url: URL) async -> Meta {
        let fallbackTitle = url.deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "_", with: " ")
        let asset = AVURLAsset(url: url)
        var title = fallbackTitle, artist = "", album = "", duration = 0.0
        var artwork: Data?
        // Best-effort: a non-audio temp file (tests) just yields the fallbacks.
        if let secs = try? await asset.load(.duration) { duration = CMTimeGetSeconds(secs) }
        if let items = try? await asset.load(.commonMetadata) {
            for item in items {
                guard let key = item.commonKey else { continue }
                let value = try? await item.load(.value)
                switch key {
                case .commonKeyTitle:  if let s = value as? String { title = s }
                case .commonKeyArtist: if let s = value as? String { artist = s }
                case .commonKeyAlbumName: if let s = value as? String { album = s }
                case .commonKeyArtwork: if let d = value as? Data { artwork = d }
                default: break
                }
            }
        }
        if duration.isNaN { duration = 0 }
        return Meta(title: title, artist: artist, album: album, duration: duration, artwork: artwork)
    }
}
```

- [ ] **Step 4: Implement DemoSeed**

Create `apps/nano-ios/Sources/Import/DemoSeed.swift`:
```swift
import Foundation
import SwiftData

/// First-run content so the shell isn't empty (handoff README — demo tracks; two are art-less to
/// show the fallback tile). Metadata-only: these aren't playable, which is fine — playback is Phase 2.
enum DemoSeed {
    @MainActor
    static func seedIfEmpty(_ ctx: ModelContext) {
        guard (try? LibraryStore.allTracks(ctx).isEmpty) ?? false else { return }
        let demos: [Track] = [
            Track(title: "Midnight Drive", artist: "Aurora Field", album: "Neon Atlas",
                  displayPath: SourceKind.local.label, durationSec: 214, format: "FLAC",
                  sampleRate: "24/96", hasEmbeddedArt: true),
            Track(title: "Glass Harbor", artist: "Aurora Field", album: "Neon Atlas",
                  displayPath: SourceKind.local.label, durationSec: 188, format: "FLAC",
                  sampleRate: "24/96", hasEmbeddedArt: true),
            Track(title: "Untitled Bounce", artist: "you", album: "Sketches",
                  displayPath: SourceKind.local.label, durationSec: 92, format: "WAV",
                  sampleRate: "24/48", hasEmbeddedArt: false),   // art-less → fallback tile
            Track(title: "Voice Memo 03", artist: "you", album: "Sketches",
                  displayPath: SourceKind.local.label, durationSec: 47, format: "M4A",
                  sampleRate: "16/44.1", hasEmbeddedArt: false), // art-less → fallback tile
        ]
        demos.forEach(ctx.insert)
    }
}
```

- [ ] **Step 5: Call the seed on first launch**

In `apps/nano-ios/Sources/NanoMetersApp.swift`, seed in `init()` after the container is built — add, right after the `do { container = ... }` block succeeds, a `MainActor` seed. Replace the `init()` body with:
```swift
    init() {
        do {
            container = try ModelContainer(for: Track.self, Playlist.self)
        } catch {
            fatalError("Failed to create ModelContainer: \(error)")
        }
        MainActor.assumeIsolated { DemoSeed.seedIfEmpty(container.mainContext) }
    }
```

- [ ] **Step 6: Run the tests → pass**

Run `xcodebuild ... test`. Expected: PASS (`ImportTests` 1 + `DemoSeedTests` 1 + earlier).

- [ ] **Step 7: Verify against the handoff (`04-data-and-sources.md` + README)**

Confirm the import matches the §04 security-scoped-bookmark recipe (`startAccessingSecurityScopedResource` → `bookmarkData` → store, plus the folder bookmark) so a stored bookmark resolves after relaunch — the test pins the round-trip. Confirm against the handoff README / §02 demo-track note that the seed includes **at least two art-less tracks**, so the fallback tile gets exercised once the Library renders (Task 7).

- [ ] **Step 8: Commit**

```bash
git add apps/nano-ios/Sources/Import apps/nano-ios/Sources/NanoMetersApp.swift \
  apps/nano-ios/Tests/ImportTests.swift apps/nano-ios/Tests/DemoSeedTests.swift
git commit -m "feat(ios): import (bookmarks + metadata) and first-run demo seed

TrackImporter resolves security-scoped bookmarks and reads best-effort
AVFoundation metadata into Track rows (handoff §04). DemoSeed populates first
run with sample tracks, two art-less to exercise the fallback. Both tested.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 5: Components — NMArtwork and NMRow

**Files:**
- Create: `apps/nano-ios/Sources/Components/NMArtwork.swift`, `apps/nano-ios/Sources/Components/NMRow.swift`

> No unit test — these are pure SwiftUI layout; the gate is `xcodebuild build` + the visual check in Task 11. Keep look/sizes pulled from `Theme`; cite handoff §02.

- [ ] **Step 1: NMArtwork (embedded art or glyph fallback)**

Create `apps/nano-ios/Sources/Components/NMArtwork.swift` (handoff §02 — fallback is a `#22252E` tile with a centered `waveform` glyph at white@22%, ~42% of the tile):
```swift
import SwiftUI

struct NMArtwork: View {
    let data: Data?
    var size: CGFloat
    var radius: CGFloat

    var body: some View {
        Group {
            if let data, let ui = UIImage(data: data) {
                Image(uiImage: ui).resizable().scaledToFill()
            } else {
                Theme.artFallback
                    .overlay(
                        Image(systemName: "waveform")
                            .font(.system(size: size * 0.42, weight: .regular))
                            .foregroundStyle(.white.opacity(0.22))
                    )
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(.white.opacity(0.06), lineWidth: 0.5)
        )
    }
}
```

- [ ] **Step 2: NMRow (Pro track row; wave/LUFS slots stubbed for Phase 3)**

Create `apps/nano-ios/Sources/Components/NMRow.swift` (handoff §02 — artwork 46/rad7, title 16/500 `text` or `accent` if current, secondary 13.5 `artist`·`album`, ellipsis 34×44 `text3`; the mini-waveform and per-track LUFS slots are intentionally empty until Phase 3):
```swift
import SwiftUI

struct NMRow: View {
    let track: Track
    var isCurrent: Bool = false
    var onEllipsis: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            NMArtwork(data: track.artworkData, size: 46, radius: Theme.Radius.albumRow)

            VStack(alignment: .leading, spacing: 2) {
                Text(track.title)
                    .font(Theme.sans(16, .medium))
                    .foregroundStyle(isCurrent ? Theme.accent : Theme.text)
                    .lineLimit(1)
                HStack(spacing: 0) {
                    Text(track.artist).foregroundStyle(Theme.text2)
                    if !track.album.isEmpty {
                        Text(" · \(track.album)").foregroundStyle(Theme.text3)
                    }
                }
                .font(Theme.sans(13.5))
                .lineLimit(1)
            }
            Spacer(minLength: 8)

            // Phase 3 fills these: a 42×20 mini-waveform and the per-track LUFS (mono, tabular).
            // Left intentionally empty in the shell.

            Button(action: onEllipsis) {
                Image(systemName: "ellipsis")
                    .font(Theme.sans(16))
                    .foregroundStyle(Theme.text3)
                    .frame(width: 34, height: 44)
            }
            .buttonStyle(.plain)
        }
        .frame(minHeight: Theme.Layout.rowMinHeight)
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 3: Build**

Run `xcodebuild ... build`. Expected: `BUILD SUCCEEDED`.

- [ ] **Step 4: Verify against the handoff (`02-components.md`)**

Cross-check the code against `02-components.md`: **NMArtwork** (§ NMArtwork) = `#22252E` tile + centered `waveform` glyph at white@22%, ~42% of the tile, 0.5px white@6% border. **NMRow** (§ NMRow) = artwork 46 / radius 7; title 16/500 (`accent` when current); secondary 13.5 = `artist` in `text2` + ` · album` in `text3`, 1-line; ellipsis 34×44 in `text3`; row min 56. Confirm the mini-waveform + per-track-LUFS slots are correctly **absent** for now (§02 lists them; they're Phase 3). Visual confirmation comes once these render in the Library (Task 7).

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Components/NMArtwork.swift apps/nano-ios/Sources/Components/NMRow.swift
git commit -m "feat(ios): NMArtwork + NMRow components (handoff §02)

Artwork tile with the white-waveform fallback for art-less tracks; the Pro
track row (artwork + title/artist + ellipsis). Mini-waveform and per-track LUFS
slots are stubbed until Phase 3. Sizes/colors come from Theme.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 6: Glass tab bar + RootView navigation

**Files:**
- Create: `apps/nano-ios/Sources/Components/GlassTabBar.swift`, `apps/nano-ios/Sources/Components/GlassRoundButton.swift`
- Modify: `apps/nano-ios/Sources/RootView.swift`

- [ ] **Step 1: GlassRoundButton (header circular action)**

Create `apps/nano-ios/Sources/Components/GlassRoundButton.swift` (handoff §02 — 38pt circle, `.ultraThinMaterial`, inset white@12%, icon `text2`):
```swift
import SwiftUI

struct GlassRoundButton: View {
    let systemName: String
    var action: () -> Void = {}
    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(Theme.sans(16, .medium))
                .foregroundStyle(Theme.text2)
                .frame(width: 38, height: 38)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Theme.glassBorder, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
```

- [ ] **Step 2: GlassTabBar (custom floating pill, locked order)**

Create `apps/nano-ios/Sources/Components/GlassTabBar.swift` (handoff §02/§03 — pill, `left/right 12`, `bottom 10`, radius 30, `.ultraThinMaterial`, inner sheen white@14% + inset white@12%; three items icon 24 over label 10.5, active `accent`/600, inactive `text2`/500; order locked Library · Playlists · Search):
```swift
import SwiftUI

enum Tab: CaseIterable {
    case library, playlists, search
    var title: String { switch self { case .library: "Library"; case .playlists: "Playlists"; case .search: "Search" } }
    var icon: String { switch self { case .library: "music.note.list"; case .playlists: "music.note.list"; case .search: "magnifyingglass" } }
}

struct GlassTabBar: View {
    @Binding var selection: Tab
    var body: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { tab in
                let active = tab == selection
                Button {
                    selection = tab
                } label: {
                    VStack(spacing: 3) {
                        Image(systemName: tab.icon).font(.system(size: 22))
                        Text(tab.title)
                            .font(Theme.sans(10.5, active ? .semibold : .medium))
                    }
                    .foregroundStyle(active ? Theme.accent : Theme.text2)
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 10)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: Theme.Radius.tabBar, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.tabBar, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 0.5)
        )
        .overlay(alignment: .top) {                       // 1px inner top sheen
            RoundedRectangle(cornerRadius: Theme.Radius.tabBar, style: .continuous)
                .stroke(Theme.glassSheen, lineWidth: 1)
                .blur(radius: 0.5)
                .mask(LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .center))
        }
        .shadow(color: .black.opacity(0.4), radius: 15, y: 8)
        .padding(.horizontal, 12)
    }
}
```

- [ ] **Step 3: RootView — own the selection + overlay the bar**

Replace `apps/nano-ios/Sources/RootView.swift` (drive selection ourselves; no system `TabView`; content fills, the bar floats over the bottom, handoff §03):
```swift
import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .library

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .library:   LibraryScreen()
                case .playlists: PlaylistsScreen()
                case .search:    SearchScreen()
                }
            }

            GlassTabBar(selection: $tab)
        }
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
```

- [ ] **Step 4: Build**

Run `xcodebuild ... build`. Expected: FAIL — `LibraryScreen`/`PlaylistsScreen`/`SearchScreen` don't exist yet. That's expected; they land in Tasks 7/8/10. To keep this task self-contained, temporarily stub them: create `apps/nano-ios/Sources/Screens/_Stubs.swift` with three `struct XScreen: View { var body: some View { Text("X") } }` placeholders, build green, then DELETE `_Stubs.swift` as each real screen lands. (Note in your commit that `_Stubs.swift` is a scaffold to be removed by Task 10.)

- [ ] **Step 5: Verify against the handoff (`02-components.md` § Glass tab bar + `Library view.heic`)**

Check the bar against § Glass tab bar: floating pill, `left/right 12` / `bottom 10`, radius 30, `.ultraThinMaterial`, inner top sheen white@14% + inset stroke white@12%; three items = icon 24 over label 10.5; active tinted `accent`/600, inactive `text2`/500; **order locked Library · Playlists · Search**. Full visual match (bar over real content) happens in Task 7 against `Library view.heic` — for now confirm the geometry, materials, and order match §02.

- [ ] **Step 6: Commit**

```bash
git add apps/nano-ios/Sources/Components/GlassTabBar.swift apps/nano-ios/Sources/Components/GlassRoundButton.swift apps/nano-ios/Sources/RootView.swift apps/nano-ios/Sources/Screens/_Stubs.swift
git commit -m "feat(ios): custom glass tab bar + RootView navigation (handoff §02/§03)

Floating .ultraThinMaterial pill, locked order Library·Playlists·Search, driven
by our own @State (no system UITabBar). Temporary screen stubs keep the build
green until the real screens land.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 7: Library screen

**Files:**
- Create: `apps/nano-ios/Sources/Screens/LibraryScreen.swift`
- Modify: `apps/nano-ios/Sources/Screens/_Stubs.swift` (remove the `LibraryScreen` stub)

- [ ] **Step 1: Implement LibraryScreen**

Create `apps/nano-ios/Sources/Screens/LibraryScreen.swift` (handoff §03A — large "Library" header + 3 glass round buttons (search/folder/gear), two stat tiles, "Songs" section header + count, `NMRow` list; tapping a row does **not** play yet — Phase 2). The folder/gear buttons are inert in the shell (their sheets are v2/Phase 4):
```swift
import SwiftUI
import SwiftData

struct LibraryScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    @Query private var playlists: [Playlist]
    @State private var importing = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Library").font(Theme.sans(32, .bold))
                        .foregroundStyle(Theme.text)
                    Spacer()
                    GlassRoundButton(systemName: "magnifyingglass")
                    GlassRoundButton(systemName: "folder") { importing = true }   // shell: import; Sources hub is v2
                    GlassRoundButton(systemName: "gearshape")                       // Settings sheet is Phase 4
                }

                HStack(spacing: 10) {
                    StatTile(icon: "music.note", title: "All Songs", detail: "\(tracks.count) tracks")
                    StatTile(icon: "rectangle.stack", title: "Playlists", detail: "\(playlists.count)")
                }

                HStack {
                    Text("Songs").font(Theme.sans(20, .bold)).foregroundStyle(Theme.text)
                    Spacer()
                    Text("\(tracks.count)").font(Theme.mono(12, .semibold)).foregroundStyle(Theme.text3)
                }
                .padding(.top, 4)

                LazyVStack(spacing: 0) {
                    ForEach(tracks) { track in
                        NMRow(track: track)
                        Divider().background(Theme.hair).padding(.leading, Theme.Layout.rowSeparatorInset)
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .padding(.top, 50)
            .padding(.bottom, Theme.Layout.scrollBottomPadding)
        }
        .background(Theme.bg)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.audio], allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                Task { _ = await TrackImporter.importFiles(urls, into: ctx) }
            }
        }
    }
}

private struct StatTile: View {
    let icon: String, title: String, detail: String
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: icon).font(.system(size: 22)).foregroundStyle(Theme.text2)
            Text(title).font(Theme.sans(15, .semibold)).foregroundStyle(Theme.text)
            Text(detail).font(Theme.mono(12.5)).foregroundStyle(Theme.text3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12).padding(.vertical, 14)
        .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.statTile, style: .continuous))
    }
}
```

- [ ] **Step 2: Remove the LibraryScreen stub**

In `apps/nano-ios/Sources/Screens/_Stubs.swift`, delete the `LibraryScreen` placeholder struct (keep the other two).

- [ ] **Step 3: Build + launch on the simulator**

Run `xcodebuild ... build`, then boot the app to confirm it renders the seeded demo tracks:
```bash
cd apps/nano-ios
xcrun simctl boot "$SIM" 2>/dev/null || true
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters -destination "platform=iOS Simulator,name=$SIM" build
APP=$(find ~/Library/Developer/Xcode/DerivedData -name 'NanoMeters.app' -path '*Debug-iphonesimulator*' | head -1)
xcrun simctl install "$SIM" "$APP" && xcrun simctl launch "$SIM" com.willeasp.nanometers.ios
cd ../..
```
Expected: launches; the Library shows the 4 demo rows (two with the waveform-glyph fallback tile). `BUILD SUCCEEDED`.

- [ ] **Step 4: Verify against the handoff (`03-screens.md` §A + `Library view.heic`)**

With the app running, put `Library view.heic` side by side (`qlmanage -p "~/Downloads/design_handoff_nanometers/Library view.heic"`) and compare to `03-screens.md` §A: large "Library" header (32/700) + three glass round buttons (search / folder / gear); two `bgElev` stat tiles (radius 16); "Songs" section header (20/700) + mono count; the `NMRow` list (two rows showing the fallback tile); the glass tab bar floating with **Library** active in amber. Tune only via `Theme` tokens — header size, tile look, row height/spacing, accent, tab-bar position are the load-bearing ones.

- [ ] **Step 5: Commit**

```bash
git add apps/nano-ios/Sources/Screens/LibraryScreen.swift apps/nano-ios/Sources/Screens/_Stubs.swift
git commit -m "feat(ios): Library screen — header, stat tiles, songs list (handoff §03A)

Large header + glass round buttons (folder triggers the document-picker import;
Sources hub/Settings are v2/Phase 4), two stat tiles, the Songs list of NMRow.
Renders the demo seed. Row taps don't play yet (Phase 2).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 8: Playlists screen + PlaylistCover + New Playlist sheet

**Files:**
- Create: `apps/nano-ios/Sources/Components/PlaylistCover.swift`, `apps/nano-ios/Sources/Screens/PlaylistsScreen.swift`, `apps/nano-ios/Sources/Screens/NewPlaylistSheet.swift`
- Modify: `apps/nano-ios/Sources/Screens/_Stubs.swift` (remove the `PlaylistsScreen` stub)

- [ ] **Step 1: PlaylistCover (2×2 mosaic)**

Create `apps/nano-ios/Sources/Components/PlaylistCover.swift` (handoff §03B — 2×2 grid of the first four tracks' artwork, radius 12; if <4, repeat the last):
```swift
import SwiftUI

struct PlaylistCover: View {
    let artworks: [Data?]   // ordered; may be < 4
    var size: CGFloat
    var body: some View {
        let cells = padded(artworks)
        let cell = size / 2
        VStack(spacing: 0) {
            HStack(spacing: 0) { tile(cells[0], cell); tile(cells[1], cell) }
            HStack(spacing: 0) { tile(cells[2], cell); tile(cells[3], cell) }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.mosaic, style: .continuous))
    }
    private func tile(_ data: Data?, _ s: CGFloat) -> some View { NMArtwork(data: data, size: s, radius: 0) }
    private func padded(_ a: [Data?]) -> [Data?] {
        if a.isEmpty { return Array(repeating: nil, count: 4) }
        var out = Array(a.prefix(4))
        while out.count < 4 { out.append(a.last!) }
        return out
    }
}
```

- [ ] **Step 2: NewPlaylistSheet (name + track selection; no autofocus)**

Create `apps/nano-ios/Sources/Screens/NewPlaylistSheet.swift` (handoff §03 sheet 5 + the §04 lesson: **do not autofocus** the name field). Create enabled only with a name + ≥1 track:
```swift
import SwiftUI
import SwiftData

struct NewPlaylistSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    @State private var name = ""
    @State private var selected = Set<UUID>()

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                TextField("Playlist name", text: $name)
                    .textFieldStyle(.plain)
                    .padding(12)
                    .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))
                Text("\(selected.count) selected").font(Theme.mono(12)).foregroundStyle(Theme.text3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                List(tracks) { t in
                    Button { toggle(t.id) } label: {
                        HStack {
                            Image(systemName: selected.contains(t.id) ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(selected.contains(t.id) ? Theme.accent : Theme.text3)
                            NMArtwork(data: t.artworkData, size: 36, radius: 6)
                            VStack(alignment: .leading) {
                                Text(t.title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.text)
                                Text(t.artist).font(Theme.sans(12.5)).foregroundStyle(Theme.text2)
                            }
                            Spacer()
                        }
                    }
                    .listRowBackground(Theme.bg)
                }
                .listStyle(.plain)
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .background(Theme.bg)
            .navigationTitle("New Playlist")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { create() }.disabled(name.isEmpty || selected.isEmpty)
                }
            }
        }
        // NOTE: intentionally no @FocusState autofocus — see handoff §04 lesson (autofocus caused a
        // layout bug in the prototype). The user taps the field.
    }

    private func toggle(_ id: UUID) { if selected.contains(id) { selected.remove(id) } else { selected.insert(id) } }

    private func create() {
        // Preserve the library's display order for the chosen ids.
        let ordered = tracks.map(\.id).filter { selected.contains($0) }
        let pl = Playlist(name: name, subtitle: "\(ordered.count) songs", itemIDs: ordered)
        ctx.insert(pl)
        dismiss()
    }
}
```

- [ ] **Step 3: PlaylistsScreen**

Create `apps/nano-ios/Sources/Screens/PlaylistsScreen.swift` (handoff §03B — header + New Playlist dashed affordance + playlist rows `[mosaic 60][name·subtitle·"N songs"][chevron]`, push to Detail):
```swift
import SwiftUI
import SwiftData

struct PlaylistsScreen: View {
    @Environment(\.modelContext) private var ctx
    @Query(sort: \Playlist.dateCreated, order: .reverse) private var playlists: [Playlist]
    @Query private var tracks: [Track]
    @State private var creating = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Playlists").font(Theme.sans(32, .bold)).foregroundStyle(Theme.text)

                    Button { creating = true } label: {
                        HStack {
                            Image(systemName: "plus")
                            Text("New Playlist").font(Theme.sans(17, .semibold))
                        }
                        .foregroundStyle(Theme.accent)
                        .frame(maxWidth: .infinity, minHeight: 60)
                        .background(
                            RoundedRectangle(cornerRadius: Theme.Radius.statTile, style: .continuous)
                                .strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [6]))
                                .foregroundStyle(Theme.text3)
                        )
                    }
                    .buttonStyle(.plain)

                    ForEach(playlists) { pl in
                        NavigationLink { PlaylistDetailScreen(playlist: pl) } label: { row(pl) }
                            .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, Theme.Layout.screenMargin)
                .padding(.top, 50)
                .padding(.bottom, Theme.Layout.scrollBottomPadding)
            }
            .background(Theme.bg)
            .sheet(isPresented: $creating) { NewPlaylistSheet() }
        }
    }

    private func row(_ pl: Playlist) -> some View {
        let arts = (try? LibraryStore.tracks(in: pl, ctx))?.map(\.artworkData) ?? []
        return HStack(spacing: 12) {
            PlaylistCover(artworks: arts, size: 60)
            VStack(alignment: .leading, spacing: 2) {
                Text(pl.name).font(Theme.sans(17, .semibold)).foregroundStyle(Theme.text)
                Text("\(pl.itemIDs.count) songs").font(Theme.mono(13)).foregroundStyle(Theme.text3)
            }
            Spacer()
            Image(systemName: "chevron.right").foregroundStyle(Theme.text3)
        }
        .frame(minHeight: 60)
        .contentShape(Rectangle())
    }
}
```

- [ ] **Step 4: Remove the PlaylistsScreen stub, build**

Delete the `PlaylistsScreen` placeholder from `_Stubs.swift`. Run `xcodebuild ... build`. Expected: FAIL — `PlaylistDetailScreen` undefined (lands in Task 9). Keep its stub in `_Stubs.swift` for now (don't remove it). Build green with that one stub remaining.

- [ ] **Step 5: Verify against the handoff (`03-screens.md` §B + `Playlist view.heic`)**

Run the app and compare Playlists to §B and `Playlist view.heic`: header + the dashed "New Playlist" tile (60pt, 1.5px dashed `text3`, `accent` plus + label); playlist rows = mosaic cover 60 + name 17/600 + "N songs" (mono / `text3`) + chevron. Create a playlist: confirm the sheet does **not** autofocus the name field (§04 lesson), the Create button enables only with a name + ≥1 track, and the new row's mosaic renders from the first four tracks.

- [ ] **Step 6: Commit**

```bash
git add apps/nano-ios/Sources/Components/PlaylistCover.swift apps/nano-ios/Sources/Screens/PlaylistsScreen.swift apps/nano-ios/Sources/Screens/NewPlaylistSheet.swift apps/nano-ios/Sources/Screens/_Stubs.swift
git commit -m "feat(ios): Playlists screen + mosaic cover + New Playlist sheet (handoff §03B)

List with the dashed New Playlist affordance and mosaic-cover rows pushing to
Detail; the create sheet selects tracks (name + >=1 required) and deliberately
does NOT autofocus the field (handoff §04 lesson).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 9: Playlist Detail screen (add / reorder / delete)

**Files:**
- Create: `apps/nano-ios/Sources/Screens/PlaylistDetailScreen.swift`
- Modify: `apps/nano-ios/Sources/Screens/_Stubs.swift` (remove the `PlaylistDetailScreen` stub)

- [ ] **Step 1: Implement PlaylistDetailScreen**

Create `apps/nano-ios/Sources/Screens/PlaylistDetailScreen.swift` (handoff §03C — centered mosaic header + name + "N songs · M min", Play/Shuffle buttons **inert in the shell** (Phase 2), the track list with native reorder/delete, and "Add Songs…"). Reorder/delete persist to `Playlist.itemIDs` via `LibraryStore`:
```swift
import SwiftUI
import SwiftData

struct PlaylistDetailScreen: View {
    @Environment(\.modelContext) private var ctx
    let playlist: Playlist
    @State private var adding = false

    private var tracks: [Track] { (try? LibraryStore.tracks(in: playlist, ctx)) ?? [] }

    var body: some View {
        List {
            Section {
                VStack(spacing: 8) {
                    PlaylistCover(artworks: tracks.map(\.artworkData), size: 176)
                    Text(playlist.name).font(Theme.sans(24, .bold)).foregroundStyle(Theme.text)
                    Text("\(tracks.count) songs · \(totalMinutes) min")
                        .font(Theme.mono(13)).foregroundStyle(Theme.text3)
                    HStack(spacing: 12) {
                        actionButton("play.fill", "Play", filled: true)     // Phase 2
                        actionButton("shuffle", "Shuffle", filled: false)   // Phase 2
                    }
                    .padding(.top, 4)
                }
                .frame(maxWidth: .infinity)
                .listRowBackground(Theme.bg)
                .listRowSeparator(.hidden)
            }

            Section {
                ForEach(tracks) { NMRow(track: $0) }
                    .onMove { from, to in LibraryStore.move(in: playlist, fromOffsets: from, toOffset: to) }
                    .onDelete { idx in LibraryStore.remove(in: playlist, atOffsets: idx) }
                    .listRowBackground(Theme.bg)

                Button { adding = true } label: {
                    Label("Add Songs…", systemImage: "plus.circle").foregroundStyle(Theme.accent)
                }
                .listRowBackground(Theme.bg)
            }
        }
        .listStyle(.plain)
        .background(Theme.bg)
        .navigationTitle(playlist.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { EditButton() }
        .sheet(isPresented: $adding) { AddSongsSheet(playlist: playlist) }
    }

    private var totalMinutes: Int { Int(tracks.reduce(0) { $0 + $1.durationSec } / 60) }

    private func actionButton(_ icon: String, _ label: String, filled: Bool) -> some View {
        HStack { Image(systemName: icon); Text(label).font(Theme.sans(16.5, .semibold)) }
            .foregroundStyle(filled ? Theme.bg : Theme.accent)
            .frame(maxWidth: .infinity, minHeight: 48)
            .background(filled ? Theme.accent : Theme.bgElev2,
                        in: RoundedRectangle(cornerRadius: Theme.Radius.button, style: .continuous))
    }
}

/// Minimal add-to-playlist picker (handoff §03 sheet 4 — toggles membership).
private struct AddSongsSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    let playlist: Playlist
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]

    var body: some View {
        NavigationStack {
            List(tracks) { t in
                let inList = playlist.itemIDs.contains(t.id)
                Button {
                    if inList { playlist.itemIDs.removeAll { $0 == t.id } } else { LibraryStore.append(t, to: playlist) }
                } label: {
                    HStack {
                        NMArtwork(data: t.artworkData, size: 36, radius: 6)
                        Text(t.title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.text)
                        Spacer()
                        Image(systemName: inList ? "checkmark" : "plus").foregroundStyle(Theme.accent)
                    }
                }
                .listRowBackground(Theme.bg)
            }
            .listStyle(.plain)
            .background(Theme.bg)
            .navigationTitle("Add Songs").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
```

- [ ] **Step 2: Remove the stub, build**

Delete the `PlaylistDetailScreen` placeholder from `_Stubs.swift` (the file should now be empty except possibly the `SearchScreen` stub — keep that one). Run `xcodebuild ... build`. Expected: FAIL only if `SearchScreen` is still referenced and stubbed (keep its stub). Build green.

- [ ] **Step 3: Verify against the handoff (`03-screens.md` §C)**

Open a playlist and compare to §C: centered 176 mosaic + name 24/700 + "N songs · M min" (mono / `text3`); Play (amber, glyph in `bg`) + Shuffle (`bgElev2`, `accent` label) buttons (48 tall / radius 14) — present but **inert** until Phase 2; the track list supports drag-to-reorder + swipe-to-delete (both persist), and "Add Songs…" (`accent`, `plus.circle`) toggles membership. No dedicated Detail screenshot exists — match §C plus the visual language of `Playlist view.heic`.

- [ ] **Step 4: Commit**

```bash
git add apps/nano-ios/Sources/Screens/PlaylistDetailScreen.swift apps/nano-ios/Sources/Screens/_Stubs.swift
git commit -m "feat(ios): Playlist Detail — header, reorder/delete, add songs (handoff §03C)

Mosaic header + meta, native onMove/onDelete persisting to Playlist.itemIDs via
LibraryStore, and an add-songs picker. Play/Shuffle are inert until Phase 2.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 10: Search screen

**Files:**
- Create: `apps/nano-ios/Sources/Screens/SearchScreen.swift`
- Delete: `apps/nano-ios/Sources/Screens/_Stubs.swift` (last stub removed)
- Test: `apps/nano-ios/Tests/SearchTests.swift`

- [ ] **Step 1: Write the failing test (pure filter logic)**

Create `apps/nano-ios/Tests/SearchTests.swift`:
```swift
import XCTest
@testable import NanoMeters

final class SearchTests: XCTestCase {
    private func mk(_ t: String, _ a: String, _ al: String) -> Track { Track(title: t, artist: a, album: al) }

    func test_filterMatchesTitleArtistAlbumCaseInsensitive() {
        let lib = [mk("Midnight Drive", "Aurora", "Neon"), mk("Glass Harbor", "Aurora", "Neon"), mk("Sketch", "you", "Demos")]
        XCTAssertEqual(SearchFilter.match(lib, query: "aur").count, 2)     // artist, case-insensitive
        XCTAssertEqual(SearchFilter.match(lib, query: "harbor").map(\.title), ["Glass Harbor"]) // title
        XCTAssertEqual(SearchFilter.match(lib, query: "demos").count, 1)   // album
        XCTAssertEqual(SearchFilter.match(lib, query: "").count, 3)        // empty → all
    }
}
```

- [ ] **Step 2: Run → fails (`SearchFilter` undefined)**

Run `xcodebuild ... test`. Expected: FAIL.

- [ ] **Step 3: Implement SearchFilter + SearchScreen**

Create `apps/nano-ios/Sources/Screens/SearchScreen.swift` (handoff §03 Search — `bgElev` field, placeholder "Songs, artists, albums", filtered `NMRow` list; empty query → all; no matches → centered "No results"). Filter logic is a pure, tested function:
```swift
import SwiftUI
import SwiftData

enum SearchFilter {
    /// Case-insensitive match across title/artist/album. Empty query returns all.
    static func match(_ tracks: [Track], query: String) -> [Track] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return tracks }
        return tracks.filter {
            $0.title.lowercased().contains(q) ||
            $0.artist.lowercased().contains(q) ||
            $0.album.lowercased().contains(q)
        }
    }
}

struct SearchScreen: View {
    @Query(sort: \Track.dateAdded, order: .reverse) private var tracks: [Track]
    @State private var query = ""

    private var results: [Track] { SearchFilter.match(tracks, query: query) }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Search").font(Theme.sans(32, .bold)).foregroundStyle(Theme.text)

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.text3)
                    TextField("Songs, artists, albums", text: $query)
                        .textFieldStyle(.plain).foregroundStyle(Theme.text)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, 12).frame(height: 40)
                .background(Theme.bgElev, in: RoundedRectangle(cornerRadius: Theme.Radius.searchField, style: .continuous))

                if results.isEmpty {
                    Text("No results").font(Theme.sans(15)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity).padding(.top, 60)
                } else {
                    LazyVStack(spacing: 0) {
                        ForEach(results) { t in
                            NMRow(track: t)
                            Divider().background(Theme.hair).padding(.leading, Theme.Layout.rowSeparatorInset)
                        }
                    }
                }
            }
            .padding(.horizontal, Theme.Layout.screenMargin)
            .padding(.top, 50)
            .padding(.bottom, Theme.Layout.scrollBottomPadding)
        }
        .background(Theme.bg)
    }
}
```

- [ ] **Step 4: Delete the now-empty stubs file**

`git rm apps/nano-ios/Sources/Screens/_Stubs.swift` (the `SearchScreen` stub was the last one). Regenerate + build to confirm no dangling references.

- [ ] **Step 5: Run tests → pass**

Run `xcodebuild ... test`. Expected: PASS (`SearchTests` + all prior).

- [ ] **Step 6: Verify against the handoff (`03-screens.md` Search + `Search view.heic`)**

Run the app and compare Search to the §Search spec and `Search view.heic`: large "Search" header + `bgElev` search field (radius 12, 40pt tall, leading `magnifyingglass`, placeholder "Songs, artists, albums"); typing filters the `NMRow` list; an empty query shows all songs; a no-match query shows a centered "No results". Adjust via `Theme` only.

- [ ] **Step 7: Commit**

```bash
git add apps/nano-ios/Sources/Screens/SearchScreen.swift apps/nano-ios/Tests/SearchTests.swift
git rm apps/nano-ios/Sources/Screens/_Stubs.swift
git commit -m "feat(ios): Search screen + tested filter (handoff §03 Search)

Inline search field filtering title/artist/album case-insensitively (pure
SearchFilter, unit-tested); empty query shows all, no matches shows 'No
results'. Removes the last temporary screen stub.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```

---

## Task 11: Final integration — full build, test, launch, visual check

**Files:** none (verification + a brief polish pass if needed).

- [ ] **Step 1: Clean generate + full test suite**

```bash
cd apps/nano-ios && xcodegen generate
SIM=$(xcrun simctl list devices available | grep -m1 -oE 'iPhone 1[0-9]( Pro)?' | head -1)
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters -destination "platform=iOS Simulator,name=$SIM" clean test
cd ../..
```
Expected: `** TEST SUCCEEDED **` — Theme, LibraryStore (3), Import (1), DemoSeed (1), Search (1), Smoke (1).

- [ ] **Step 2: Launch and walk the shell**

Build + install + launch (as in Task 7 Step 3). Manually verify against the four reference `.heic` screenshots in `~/Downloads/design_handoff_nanometers/`:
- **Library**: large title, three glass round buttons, two stat tiles, Songs list with the 4 demo rows (two showing the waveform-glyph fallback tile). Glass tab bar floats at the bottom, **Library** active in amber.
- **Playlists**: dashed "New Playlist" affordance; create one (name + pick tracks, field does not autofocus); it appears with a mosaic cover; open it; reorder + swipe-delete work; "Add Songs…" toggles membership.
- **Search**: typing filters the list; clearing shows all; a nonsense query shows "No results".
- Tap the **folder** button on Library → the system document picker appears (importing real files adds rows).

- [ ] **Step 3: Tighten any visual drift**

Compare spacing/typography/colors to §01 and the screenshots; adjust only via `Theme` tokens (don't scatter literals). Tab-bar position, row height (56), header sizes (32/700), and the amber accent are the load-bearing ones. Keep changes minimal.

- [ ] **Step 4: Commit any polish**

```bash
git add -A
git commit -m "polish(ios): Phase 1 shell visual pass against handoff §01 + screenshots

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>"
```
(Skip the commit if Step 3 found nothing to change.)

---

## Done criteria (Phase 1 shell complete)

- `xcodegen generate` + `xcodebuild ... test` on an iPhone simulator → all unit tests green (Theme, LibraryStore, Import, DemoSeed, Search, Smoke).
- App launches and shows the demo-seeded Library, including the art-less fallback tiles.
- Tabs switch via the custom glass bar (no system `UITabBar`); order is Library · Playlists · Search.
- Document-picker import adds real tracks (bookmark stored + resolvable).
- Playlists: create (no autofocus), mosaic cover, Detail with reorder/delete, add songs — all persisted to SwiftData.
- Search filters by title/artist/album; empty/no-match states correct.
- No playback, waveforms, LUFS, MiniPlayer, NowPlaying, or DSP link (correctly deferred to Phases 2–4).
- Layout/colors read from `Theme` (handoff §01); no hard-coded tokens scattered in views.

**Next:** Phase 2 (local playback: `AudioEngine`, transport, queue/context, sample-time progress, `MPNowPlayingInfoCenter`, `MiniPlayer`) gets its own plan — it's where row taps start playing and the mini player docks above this tab bar.
