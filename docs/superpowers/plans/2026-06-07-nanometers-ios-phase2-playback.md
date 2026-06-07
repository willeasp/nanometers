# Nanometers iOS — Phase 2: Local Playback Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping a track plays it through a real `AVAudioEngine`, with a docked MiniPlayer, sample-accurate progress, full transport (next / prev / repeat / shuffle), "Playing from" context, and lock-screen / remote-command integration — demonstrable out of the box via two bundled sample tracks.

**Architecture:** A pure `PlaybackQueue` value type holds the ordered tracks + index + shuffle/repeat flags and all transport *transitions* (next / prev-restart / jump / shuffle) — no AVFoundation, so it is the unit-tested core (handoff §03/§04). A `@MainActor @Observable AudioEngine` owns one `PlaybackQueue` plus an `AVAudioEngine`/`AVAudioPlayerNode`; it resolves a Track to a file URL — **a bundled sample by name, or an imported file via its security-scoped bookmark** — opens an `AVAudioFile`, schedules it, derives `progress` from the player node's **sample time** (not a wall-clock timer), and wires `AVAudioSession` / `MPNowPlayingInfoCenter` / `MPRemoteCommandCenter`. SwiftUI reads the engine from the environment: `NMRow` taps drive `play(_:in:context:)`, the `MiniPlayer` docks above the glass tab bar, and Playlist Detail's Play/Shuffle buttons start playback.

**Tech Stack:** SwiftUI + Observation (`@Observable`, `@Environment`), AVFoundation (`AVAudioEngine`, `AVAudioPlayerNode`, `AVAudioFile`, `AVAudioSession`), MediaPlayer (`MPNowPlayingInfoCenter`, `MPRemoteCommandCenter`), SwiftData (existing), XCTest. iOS 17+, iPhone, portrait. Built/tested on the **iOS 26.5 iPhone 17 Pro** simulator (UDID `F8BC6E09-E5E4-4054-A03B-B1434DF0838D`).

---

## Design handoff — the canonical source, verify against it

The locked design lives in **`/Users/wasp/Downloads/design_handoff_nanometers/`**. Do **not** restate its numbers from this plan as if they were truth — open the handoff and confirm. Phase 2 touches:

- **`02-components.md`** — `## Mini player (docked)`, `## NMRow — track row`, the SF Symbol table (`play.fill`/`pause.fill`/`forward.fill`/`backward.fill`/`waveform`).
- **`03-screens.md`** — `## A) Library` / `## C) Playlist Detail` (Play/Shuffle), `## E) Mini player`, `## "Playing from" context`, and the global note ("mini player docks just above [the tab bar]; pad the scroll bottom ~168pt while playing, ~100pt otherwise").
- **`04-data-and-sources.md`** — `## Playback / queue state (AudioEngine)` (the interface this phase implements verbatim in spirit), security-scoped bookmark resolution on playback.
- **`design_reference/app.jsx`** — the prototype transport state machine (`goNext` / `goPrev` / `play` / `playShuffle` / `jumpTo`); the **behaviour** reference, not the API.
- **Screenshot `Library view with collapsed player.heic`** — the only reference frame showing the docked MiniPlayer. Convert with `sips -s format png "<file>.heic" --out /tmp/<name>.png` to view.

Each UI/behaviour task ends with a **"Verify against the handoff"** step naming the exact section/screenshot. Confirm the build matches it before marking the task complete; if the plan and the handoff disagree, the **handoff wins** — fix the code and flag the plan.

The project design spec (already reconciled with the handoff) is `docs/superpowers/specs/2026-06-06-nanometers-ios-design.md` — Phase 2 line and the "Playback / queue state" testing notes.

---

## Demo content + your own audio

The app **ships two real, playable sample tracks** in its bundle (`Resources/biljam.mp3`, `Resources/Mercy.mp3`), seeded on first run (Task 2) — so playback works the moment the app launches, no import needed. Neither has embedded artwork, so they also exercise the fallback art tile.

> **Shipping note:** these are placeholder demo assets. Before any public release, confirm distribution rights for each clip (or swap for cleared/CC content). For dev + TestFlight they're fine.

To add **more** tracks (your own), Task 1 enables in-place file access; then either drag audio from Finder onto the booted Simulator (lands in Files → in-app folder button → pick), or CLI-mirror a Mac folder into the sandbox:
```sh
APP_DATA=$(xcrun simctl get_app_container F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios data)
cp ~/path/to/tracks/*.{wav,mp3,m4a,flac,aif,aiff} "$APP_DATA/Documents/" 2>/dev/null
# in-app: folder → On My iPhone › NanoMeters → select → import
```

---

## File Structure

New files (all under `apps/nano-ios/`):

| File | Responsibility |
|---|---|
| `Resources/biljam.mp3`, `Resources/Mercy.mp3` | Bundled sample tracks (already staged in the worktree). |
| `Sources/Playback/PlayContext.swift` | The "Playing from" label value (`kind` + `name`) with `.library` / `.playlist(_:)` / `.search` factories. |
| `Sources/Playback/PlaybackQueue.swift` | **Pure** transport state machine: ordered tracks, index, shuffle/repeat, and the next/prev/jump/shuffle transitions. No AVFoundation. |
| `Sources/Playback/PlaybackMath.swift` | **Pure** helpers: sample-frame → 0…1 fraction; seconds → `M:SS` clock. |
| `Sources/Playback/AudioEngine.swift` | `@MainActor @Observable` engine: `AVAudioEngine`/`AVAudioPlayerNode`, bundled/bookmark URL resolution, scheduling, sample-time progress, transport, session, now-playing/remote. |
| `Sources/Components/MiniPlayer.swift` | Docked mini player (handoff §02). |
| `Tests/PlaybackQueueTests.swift` | Unit tests for every `PlaybackQueue` transition. |
| `Tests/PlaybackMathTests.swift` | Unit tests for fraction/clock math. |

Modified files:

| File | Change |
|---|---|
| `Sources/Info.plist` (+ `project.yml`) | `UIFileSharingEnabled`, `LSSupportsOpeningDocumentsInPlace`, `UIBackgroundModes:[audio]`; `project.yml` adds `Resources` to the target's sources. |
| `Sources/Model/Track.swift` | Add `bundledName: String?` (set for bundled samples; nil for imported tracks). |
| `Sources/Import/DemoSeed.swift` | Reseed two bundled playable tracks instead of four silent ones. |
| `Tests/DemoSeedTests.swift` | Expect two bundled tracks (`bundledName != nil`); idempotent. |
| `Sources/Components/NMRow.swift` | Current-track artwork overlay (scrim + glyph); `isPlaying` + `onTap` params. |
| `Sources/RootView.swift` | Own the `AudioEngine`, inject into environment, stack `MiniPlayer` above the tab bar. |
| `Sources/Screens/LibraryScreen.swift` | Wire row taps (`.library`), current/playing flags, playing bottom-pad. |
| `Sources/Screens/SearchScreen.swift` | Wire row taps (`.search`), current/playing flags, playing bottom-pad. |
| `Sources/Screens/PlaylistDetailScreen.swift` | Wire row taps (`.playlist`), Play/Shuffle buttons, playing bottom-pad. |
| `Sources/Theme/Theme.swift` | `Layout.scrollBottomPaddingPlaying = 168`. |
| `Tests/ImportTests.swift` | Add a real-WAV import test (synthesized in-test). |

---

## Scope

**In this phase:** real local-file playback (bundled samples + imported files); the pure queue/transport core; sample-time progress; the docked MiniPlayer (play/pause, next, progress bar); NMRow tap-to-play + current-track indicator across Library / Search / Playlist Detail; Playlist Detail Play/Shuffle; "Playing from" context; `AVAudioSession` + background-audio mode; `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter`.

**Deferred (later phases, do NOT build here):**
- **Now Playing full screen** + `matchedGeometryEffect` + transport row UI (shuffle/repeat/volume toggles) + heart → **Phase 4**. In Phase 2 the MiniPlayer's body tap takes an `onTapBody` closure that is currently a no-op; `repeat` has no on-screen control yet (engine + remote support it).
- **MiniWave / OverviewWaveform / per-track & live LUFS / nano-dsp link** → **Phase 3/5**. The MiniPlayer's optional 56×22 mini-waveform slot (handoff §02) is omitted now.
- **Queue / Up-Next sheet, context menu, Sources** → later.

**Out of scope:** anything not in the handoff; iPad; landscape.

---

## Task 1: Import works in the Simulator (the testability foundation)

**Files:**
- Modify: `apps/nano-ios/Sources/Info.plist`
- Modify: `apps/nano-ios/project.yml`
- Modify: `apps/nano-ios/Tests/ImportTests.swift`

- [ ] **Step 1: Add the file-access keys to `Info.plist`**

In `apps/nano-ios/Sources/Info.plist`, inside the top-level `<dict>`, add:

```xml
	<key>LSSupportsOpeningDocumentsInPlace</key>
	<true/>
	<key>UIFileSharingEnabled</key>
	<true/>
```

- [ ] **Step 2: Mirror the keys into `project.yml`** (the file at `INFOPLIST_FILE` is authoritative; keep them in sync)

In `apps/nano-ios/project.yml`, under `targets: NanoMeters: info: properties:`, add:

```yaml
        UIFileSharingEnabled: true
        LSSupportsOpeningDocumentsInPlace: true
```

- [ ] **Step 3: Write a failing test — importing a *real* WAV reads its duration**

Append to `apps/nano-ios/Tests/ImportTests.swift` (inside the class). It synthesizes a 1-second WAV with `AVAudioFile` (no committed fixture), imports it, and asserts real metadata came through:

```swift
    func test_importReadsRealAudioDuration() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Tone_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        // Write 1.0s of silence at 44.1k mono → a valid WAV AVURLAsset can read.
        let sr = 44_100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 1, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sr) // 1 second
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        try file.write(from: buf)

        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)

        let n = await TrackImporter.importFiles([url], into: ctx)
        XCTAssertEqual(n, 1)
        let t = try LibraryStore.allTracks(ctx)[0]
        XCTAssertEqual(t.format, "WAV")
        XCTAssertEqual(t.durationSec, 1.0, accuracy: 0.1)   // real duration, not a fallback
    }
```

Add `import AVFoundation` to the top of `ImportTests.swift` if not present.

- [ ] **Step 4: Run it — expect PASS** (the existing importer already reads `.duration`; this proves it end-to-end against real audio)

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/ImportTests 2>&1 | tail -20
```
Expected: `Test Suite 'ImportTests' passed`. If `durationSec` is 0, the importer regressed — fix `TrackImporter.readMetadata` before proceeding.

- [ ] **Step 5: Confirm the capability on the running app**

```sh
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
APP="build/Build/Products/Debug-iphonesimulator/NanoMeters.app"
/usr/libexec/PlistBuddy -c "Print :UIFileSharingEnabled" "$APP/Info.plist"          # → true
/usr/libexec/PlistBuddy -c "Print :LSSupportsOpeningDocumentsInPlace" "$APP/Info.plist"  # → true
```
Both keys must print `true`.

- [ ] **Step 6: Commit**

```sh
git add apps/nano-ios/Sources/Info.plist apps/nano-ios/project.yml apps/nano-ios/Tests/ImportTests.swift
git commit -m "feat(ios): enable in-place file access + real-audio import test"
```

- [ ] **Verify against the handoff:** `04-data-and-sources.md` — security-scoped bookmark *import* path (Connecting / importing) and the `.audio` document picker. No visual change.

---

## Task 2: Ship two bundled sample tracks (replace the demo seed)

**Files:**
- Add: `apps/nano-ios/Resources/biljam.mp3`, `apps/nano-ios/Resources/Mercy.mp3` (already staged in the worktree)
- Modify: `apps/nano-ios/project.yml`
- Modify: `apps/nano-ios/Sources/Model/Track.swift`
- Modify: `apps/nano-ios/Sources/Import/DemoSeed.swift`
- Modify: `apps/nano-ios/Tests/DemoSeedTests.swift`

> The two MP3s are already copied into `apps/nano-ios/Resources/`. If absent, restage:
> ```sh
> mkdir -p apps/nano-ios/Resources
> cp "/Users/wasp/Library/Mobile Documents/com~apple~CloudDocs/Musik/biljam.mp3" apps/nano-ios/Resources/
> cp "/Users/wasp/Library/Mobile Documents/com~apple~CloudDocs/Musik/Mercy.mp3" apps/nano-ios/Resources/
> ```

- [ ] **Step 1: Bundle the `Resources/` folder** — in `apps/nano-ios/project.yml`, change the app target's sources:

```yaml
    sources: [Sources, Resources]
```
(XcodeGen adds the `.mp3` files to the app's Copy-Bundle-Resources phase; they are not compiled.)

- [ ] **Step 2: Add `bundledName` to the `Track` model**

In `apps/nano-ios/Sources/Model/Track.swift`, add the stored property near the source/location group:
```swift
    var bundledName: String?      // resource filename for tracks that ship in the app bundle
```
Add the init parameter (default nil) — place it right after `artworkData`:
```swift
        artworkData: Data? = nil,
        bundledName: String? = nil,
```
and the assignment in `init` (after `self.artworkData = artworkData`):
```swift
        self.bundledName = bundledName
```

- [ ] **Step 3: Rewrite `DemoSeed.swift`** to seed the two bundled, playable tracks

```swift
import Foundation
import SwiftData

/// First-run content: two real, playable sample tracks that ship in the app bundle
/// (`Resources/biljam.mp3`, `Resources/Mercy.mp3`). Neither has embedded artwork, so they also
/// exercise the fallback art tile. Imported files (handoff §04) add more on top of these.
enum DemoSeed {
    @MainActor
    static func seedIfEmpty(_ ctx: ModelContext) {
        guard (try? LibraryStore.allTracks(ctx).isEmpty) ?? false else { return }
        let demos: [Track] = [
            Track(title: "Biljam", artist: "you", album: "Demos",
                  displayPath: SourceKind.local.label, durationSec: 70, format: "MP3",
                  sampleRate: "320", hasEmbeddedArt: false, bundledName: "biljam.mp3"),
            Track(title: "Mercy", artist: "you", album: "Demos",
                  displayPath: SourceKind.local.label, durationSec: 220, format: "MP3",
                  sampleRate: "320", hasEmbeddedArt: false, bundledName: "Mercy.mp3"),
        ]
        demos.forEach(ctx.insert)
    }
}
```
(Title/artist/album are editable placeholders — the MP3s carry no tags.)

- [ ] **Step 4: Update `DemoSeedTests.swift`** to expect the two bundled tracks

Replace the seed-count test body so it asserts two tracks, both with a `bundledName`, and idempotency:
```swift
    func test_seedsTwoBundledTracksOnceWhenEmpty() throws {
        let ctx = try makeContext()
        DemoSeed.seedIfEmpty(ctx)
        let seeded = try LibraryStore.allTracks(ctx)
        XCTAssertEqual(seeded.count, 2)
        XCTAssertTrue(seeded.allSatisfy { $0.bundledName != nil })
        DemoSeed.seedIfEmpty(ctx)                              // idempotent — already populated
        XCTAssertEqual(try LibraryStore.allTracks(ctx).count, 2)
    }
```
(Keep the existing `makeContext()` helper; rename/replace the old count test. If the file lacks `makeContext`, mirror `LibraryStoreTests`'s in-memory container helper.)

- [ ] **Step 5: Regenerate, build, and confirm the MP3s are actually bundled**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
ls build/Build/Products/Debug-iphonesimulator/NanoMeters.app/*.mp3   # → biljam.mp3  Mercy.mp3
```
Both files must be listed inside the `.app`. If not, the `sources: [Sources, Resources]` change didn't take — re-run `xcodegen generate`.

- [ ] **Step 6: Install, launch, screenshot — the seeded library now shows the two tracks**

```sh
APP="build/Build/Products/Debug-iphonesimulator/NanoMeters.app"
xcrun simctl uninstall F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios  # clear old seed
xcrun simctl install   F8BC6E09-E5E4-4054-A03B-B1434DF0838D "$APP"
xcrun simctl launch    F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios
xcrun simctl io        F8BC6E09-E5E4-4054-A03B-B1434DF0838D screenshot /tmp/nano-p2-seed.png
```
Read `/tmp/nano-p2-seed.png`: "All Songs · 2 tracks", rows "Biljam" and "Mercy" with the fallback art tile. (Uninstall clears the Phase-1 four-track seed so the new seed runs.)

- [ ] **Step 7: Run the unit suite — expect PASS**

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -20
```

- [ ] **Step 8: Commit**

```sh
git add apps/nano-ios/Resources apps/nano-ios/project.yml apps/nano-ios/Sources/Model/Track.swift apps/nano-ios/Sources/Import/DemoSeed.swift apps/nano-ios/Tests/DemoSeedTests.swift
git commit -m "feat(ios): ship two bundled sample tracks as the demo seed"
```

- [ ] **Verify against the handoff:** `02-components.md` NMArtwork fallback (art-less tracks → glyph tile); `03-screens.md` "A) Library" (All Songs count + track list). The seeded rows render exactly like any track.

---

## Task 3: `PlaybackQueue` — the pure transport state machine

**Files:**
- Create: `apps/nano-ios/Sources/Playback/PlayContext.swift`
- Create: `apps/nano-ios/Sources/Playback/PlaybackQueue.swift`
- Test: `apps/nano-ios/Tests/PlaybackQueueTests.swift`

- [ ] **Step 1: Create `PlayContext.swift`**

```swift
import Foundation

/// The "Playing from" label the engine carries so Now Playing / the queue can show where
/// playback started (handoff §03 "Playing from context"). Set at the moment a track is tapped.
struct PlayContext: Equatable {
    var kind: String   // e.g. "PLAYING FROM LIBRARY"
    var name: String   // e.g. "All Songs"

    static let library = PlayContext(kind: "PLAYING FROM LIBRARY", name: "All Songs")
    static let search  = PlayContext(kind: "PLAYING FROM SEARCH",  name: "Search")
    static func playlist(_ name: String) -> PlayContext {
        PlayContext(kind: "PLAYING FROM PLAYLIST", name: name)
    }
}
```

- [ ] **Step 2: Write the failing tests** in `apps/nano-ios/Tests/PlaybackQueueTests.swift`

These pin every transition to the handoff rules (§03: prev >5% restart; end-of-queue stop unless repeat → 0). Tracks are made in an in-memory SwiftData context, matching `LibraryStoreTests`.

```swift
import XCTest
import SwiftData
@testable import NanoMeters

@MainActor
final class PlaybackQueueTests: XCTestCase {
    private func tracks(_ n: Int) throws -> [Track] {
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: Track.self, Playlist.self, configurations: config)
        let ctx = ModelContext(container)
        let ts = (0..<n).map { Track(title: "T\($0)", artist: "", album: "") }
        ts.forEach(ctx.insert)
        return ts
    }

    func test_loadStartsAtChosenIndex() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue()
        let started = q.load(ts, startingAt: 1)
        XCTAssertEqual(started?.id, ts[1].id)
        XCTAssertEqual(q.current?.id, ts[1].id)
    }

    func test_advanceMovesForward() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 0)
        XCTAssertEqual(q.advance()?.id, ts[1].id)
        XCTAssertEqual(q.advance()?.id, ts[2].id)
    }

    func test_advanceAtEndStopsWhenNoRepeat() throws {
        let ts = try tracks(2)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 1)
        XCTAssertNil(q.advance())            // end of queue → stop
        XCTAssertEqual(q.current?.id, ts[1].id)  // index unchanged
    }

    func test_advanceAtEndWrapsWhenRepeat() throws {
        let ts = try tracks(2)
        var q = PlaybackQueue(isRepeat: true); _ = q.load(ts, startingAt: 1)
        XCTAssertEqual(q.advance()?.id, ts[0].id)  // wrap to 0
    }

    func test_prevRestartsWhenPastThreshold() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 2)
        if case .restartCurrent = q.goPrev(progress: 0.10) {} else { XCTFail("expected restart") }
        XCTAssertEqual(q.current?.id, ts[2].id)   // stays on current
    }

    func test_prevStepsBackWhenEarly() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 2)
        guard case .play(let t) = q.goPrev(progress: 0.02) else { return XCTFail("expected play") }
        XCTAssertEqual(t.id, ts[1].id)
        XCTAssertEqual(q.current?.id, ts[1].id)
    }

    func test_prevAtStartStaysAtZero() throws {
        let ts = try tracks(3)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 0)
        guard case .play(let t) = q.goPrev(progress: 0.0) else { return XCTFail("expected play") }
        XCTAssertEqual(t.id, ts[0].id)
        XCTAssertEqual(q.current?.id, ts[0].id)
    }

    func test_jumpToIndex() throws {
        let ts = try tracks(4)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 0)
        XCTAssertEqual(q.jump(to: 3)?.id, ts[3].id)
        XCTAssertNil(q.jump(to: 9))               // out of range → nil, index unchanged
        XCTAssertEqual(q.current?.id, ts[3].id)
    }

    func test_loadShuffledPreservesSetAndPutsChosenFirst() throws {
        let ts = try tracks(5)
        var q = PlaybackQueue()
        let first = q.loadShuffled(ts, firstIndex: 3)
        XCTAssertEqual(first?.id, ts[3].id)               // chosen track is current
        XCTAssertEqual(q.current?.id, ts[3].id)
        XCTAssertTrue(q.isShuffle)
        XCTAssertEqual(Set(ts.map(\.id)).count, 5)        // no tracks lost
    }
}
```

- [ ] **Step 3: Run them — expect FAIL** ("cannot find 'PlaybackQueue'")

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/PlaybackQueueTests 2>&1 | tail -20
```

- [ ] **Step 4: Implement `PlaybackQueue.swift`**

```swift
import Foundation

/// Pure transport state machine — the ordered queue, the current index, the shuffle/repeat
/// flags, and every next/prev/jump/shuffle transition. No AVFoundation: this is the piece the
/// spec calls out for unit tests (handoff §03 transport rules, §04 AudioEngine). The AudioEngine
/// owns one and turns its outputs into actual scheduling. Mirrors `app.jsx` goNext/goPrev/jumpTo.
struct PlaybackQueue {
    /// Fraction-into-track at/below which `prev` steps back instead of restarting
    /// (handoff §03: "prev: if >5% into the track, restart it; else go to previous track").
    static let prevRestartThreshold = 0.05

    /// What `prev` resolved to: restart the current track, or load a different one.
    enum PrevAction { case restartCurrent, play(Track) }

    private(set) var tracks: [Track] = []
    private(set) var index: Int = 0
    var isShuffle: Bool = false
    var isRepeat: Bool = false

    init(isShuffle: Bool = false, isRepeat: Bool = false) {
        self.isShuffle = isShuffle
        self.isRepeat = isRepeat
    }

    var current: Track? { tracks.indices.contains(index) ? tracks[index] : nil }

    /// Replace the queue with `list`, starting at `start` (clamped). Returns the track to play.
    mutating func load(_ list: [Track], startingAt start: Int) -> Track? {
        tracks = list
        index = list.indices.contains(start) ? start : 0
        return current
    }

    /// Replace the queue with a shuffled `list`; the element at `firstIndex` becomes current
    /// (callers pass a random index; tests pass a fixed one). Sets `isShuffle`.
    mutating func loadShuffled(_ list: [Track], firstIndex: Int) -> Track? {
        var rest = list
        var ordered: [Track] = []
        if rest.indices.contains(firstIndex) { ordered.append(rest.remove(at: firstIndex)) }
        rest.shuffle()
        ordered.append(contentsOf: rest)
        tracks = ordered
        index = 0
        isShuffle = true
        return current
    }

    /// Next track. Returns nil if playback should STOP (end of queue, repeat off); with repeat
    /// on, wraps to 0. On stop, `index` is left unchanged.
    mutating func advance() -> Track? {
        guard !tracks.isEmpty else { return nil }
        let next = index + 1
        if next >= tracks.count {
            guard isRepeat else { return nil }
            index = 0
            return current
        }
        index = next
        return current
    }

    /// Prev semantics (handoff §03). Mutates `index` only when stepping to a previous track.
    mutating func goPrev(progress: Double) -> PrevAction {
        if progress > Self.prevRestartThreshold { return .restartCurrent }
        index = max(0, index - 1)
        return .play(current ?? tracks.first ?? tracks[index])
    }

    /// Jump to an explicit index; nil (and no change) if out of range.
    mutating func jump(to i: Int) -> Track? {
        guard tracks.indices.contains(i) else { return nil }
        index = i
        return current
    }
}
```

- [ ] **Step 5: Run the tests — expect PASS** (re-run the Step 3 command). All 10 green.

- [ ] **Step 6: Commit**

```sh
git add apps/nano-ios/Sources/Playback/PlayContext.swift apps/nano-ios/Sources/Playback/PlaybackQueue.swift apps/nano-ios/Tests/PlaybackQueueTests.swift
git commit -m "feat(ios): pure PlaybackQueue transport state machine + tests"
```

- [ ] **Verify against the handoff:** `03-screens.md` "Behavior" bullets (prev >5% restart; next-at-end stop unless repeat) and `app.jsx` `goNext`/`goPrev`/`jumpTo`/`playShuffle`. Logic-only; no visual.

---

## Task 4: `AudioEngine` core — load, play, toggle, sample-time progress

**Files:**
- Create: `apps/nano-ios/Sources/Playback/PlaybackMath.swift`
- Create: `apps/nano-ios/Sources/Playback/AudioEngine.swift`
- Test: `apps/nano-ios/Tests/PlaybackMathTests.swift`

> **Note on testing:** actual audio output can't be asserted headlessly, so the *pure* math is unit-tested here and the engine's audio behaviour is verified manually on the simulator (Step 6). Keep all derivable logic in `PlaybackMath` / `PlaybackQueue` so it stays testable.

- [ ] **Step 1: Write failing tests** in `apps/nano-ios/Tests/PlaybackMathTests.swift`

```swift
import XCTest
import AVFoundation
@testable import NanoMeters

final class PlaybackMathTests: XCTestCase {
    func test_fractionMidpoint() {
        XCTAssertEqual(PlaybackMath.fraction(frame: 50, total: 100), 0.5, accuracy: 1e-9)
    }
    func test_fractionGuardsZeroTotal() {
        XCTAssertEqual(PlaybackMath.fraction(frame: 10, total: 0), 0)
    }
    func test_fractionClampsOverrun() {
        XCTAssertEqual(PlaybackMath.fraction(frame: 150, total: 100), 1)
        XCTAssertEqual(PlaybackMath.fraction(frame: -5, total: 100), 0)
    }
    func test_clockFormatsMinutesSeconds() {
        XCTAssertEqual(PlaybackMath.clock(0), "0:00")
        XCTAssertEqual(PlaybackMath.clock(9), "0:09")
        XCTAssertEqual(PlaybackMath.clock(75), "1:15")
        XCTAssertEqual(PlaybackMath.clock(-3), "0:00")
    }
}
```

- [ ] **Step 2: Run them — expect FAIL** ("cannot find 'PlaybackMath'")

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/PlaybackMathTests 2>&1 | tail -15
```

- [ ] **Step 3: Implement `PlaybackMath.swift`**

```swift
import AVFoundation

/// Pure playback math, kept out of `AudioEngine` so it's unit-testable. `progress` is derived
/// from the player node's sample time (handoff §04: "derive from sample time, not a timer").
enum PlaybackMath {
    /// 0…1 position from current sample frame and total frames; guards div-by-zero and overrun.
    static func fraction(frame: AVAudioFramePosition, total: AVAudioFramePosition) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, Double(frame) / Double(total)))
    }

    /// "M:SS" from seconds, for the mono elapsed/remaining clock.
    static func clock(_ seconds: Double) -> String {
        let s = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}
```

- [ ] **Step 4: Run the math tests — expect PASS** (re-run Step 2 command).

- [ ] **Step 5: Implement `AudioEngine.swift`** (core only — transport methods land in Task 5, now-playing/remote in Task 10; the stubs referenced here are added then)

```swift
import Foundation
import AVFoundation
import Observation

/// The playback engine (handoff §04). `@MainActor @Observable` so SwiftUI reads `current`,
/// `isPlaying`, `progress` directly. Owns a pure `PlaybackQueue` and an `AVAudioEngine`/
/// `AVAudioPlayerNode`; resolves a Track to a file URL (bundled sample by name, else imported
/// file via its security-scoped bookmark), opens an `AVAudioFile`, schedules it, and derives
/// `progress` from the node's sample time. Tracks with no resolvable file are a no-op — we never
/// fake audio.
@MainActor
@Observable
final class AudioEngine {
    // Observable transport state.
    private(set) var current: Track?
    private(set) var isPlaying = false
    private(set) var progress: Double = 0    // 0…1
    private(set) var elapsed: Double = 0     // seconds
    private(set) var context: PlayContext = .library
    var isRepeat: Bool {
        get { queue.isRepeat }
        set { queue.isRepeat = newValue; updateNowPlayingInfo() }
    }
    var isShuffle: Bool { queue.isShuffle }

    // Queue + audio graph.
    var queue = PlaybackQueue()
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private var file: AVAudioFile?
    private var scopedURL: URL?
    private var sampleRate: Double = 44_100
    private var totalFrames: AVAudioFramePosition = 0
    private var seekOffsetFrames: AVAudioFramePosition = 0
    private var scheduleToken = 0            // invalidates stale completion callbacks
    private var ticker: Timer?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: nil)
        configureSession()
        configureRemoteCommands()            // Task 10
    }

    // MARK: Public API (handoff §04)

    func play(_ track: Track, in list: [Track], context: PlayContext) {
        self.context = context
        let start = list.firstIndex { $0.id == track.id } ?? 0
        if let t = queue.load(list, startingAt: start) { loadAndStart(t) }
    }

    func toggle() {
        guard current != nil, file != nil else { return }   // nothing loaded / unresolved file
        if isPlaying {
            player.pause(); isPlaying = false; stopTicker()
        } else {
            if !engine.isRunning { try? engine.start() }
            player.play(); isPlaying = true; startTicker()
        }
        updateNowPlayingInfo()
    }

    // MARK: Loading / scheduling

    private func loadAndStart(_ track: Track) {
        stopTicker()
        player.stop()
        releaseScope()
        progress = 0; elapsed = 0; seekOffsetFrames = 0

        guard let url = resolveURL(track) else {
            // Unresolved file: reflect the selection, but don't fake audio.
            current = track; isPlaying = false; file = nil; totalFrames = 0
            updateNowPlayingInfo()
            NSLog("[AudioEngine] no playable file for \(track.title) — selection only")
            return
        }
        do {
            let f = try AVAudioFile(forReading: url)
            file = f
            totalFrames = f.length
            sampleRate = f.processingFormat.sampleRate
            engine.connect(player, to: engine.mainMixerNode, format: f.processingFormat)
            if !engine.isRunning { try engine.start() }
            schedule(f, from: 0)
            current = track
            player.play(); isPlaying = true
            startTicker()
            updateNowPlayingInfo()
        } catch {
            current = track; isPlaying = false; file = nil; totalFrames = 0
            NSLog("[AudioEngine] load failed for \(url.lastPathComponent): \(error)")
        }
    }

    /// Schedule `f` from `startFrame` to its end; advance to the next track when it finishes
    /// naturally (guarded by `scheduleToken` so manual stop/seek don't trigger an advance).
    private func schedule(_ f: AVAudioFile, from startFrame: AVAudioFramePosition) {
        scheduleToken &+= 1
        let token = scheduleToken
        seekOffsetFrames = startFrame
        let remaining = AVAudioFrameCount(max(0, totalFrames - startFrame))
        guard remaining > 0 else { handlePlaybackEnded(token: token); return }
        player.scheduleSegment(f, startingFrame: startFrame, frameCount: remaining, at: nil,
                               completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor in self?.handlePlaybackEnded(token: token) }
        }
    }

    private func handlePlaybackEnded(token: Int) {
        guard token == scheduleToken else { return }   // superseded by seek / next / new load
        next()                                           // Task 5
    }

    /// Bundled samples resolve by name (no security scope); imported tracks via their bookmark.
    private func resolveURL(_ track: Track) -> URL? {
        if let name = track.bundledName,
           let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return url
        }
        guard let bm = track.bookmark else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale) else { return nil }
        if url.startAccessingSecurityScopedResource() { scopedURL = url }
        return url
    }

    private func releaseScope() {
        scopedURL?.stopAccessingSecurityScopedResource()
        scopedURL = nil
    }

    // MARK: Progress (sample time)

    private var currentFrame: AVAudioFramePosition {
        guard let nodeTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: nodeTime) else { return seekOffsetFrames }
        return seekOffsetFrames + playerTime.sampleTime
    }

    func updateProgress() {
        progress = PlaybackMath.fraction(frame: currentFrame, total: totalFrames)
        elapsed = sampleRate > 0 ? Double(currentFrame) / sampleRate : 0
    }

    private func startTicker() {
        stopTicker()
        ticker = Timer.scheduledTimer(withTimeInterval: 1.0 / 20.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateProgress() }
        }
    }
    private func stopTicker() { ticker?.invalidate(); ticker = nil }

    // MARK: Session

    private func configureSession() {
        let s = AVAudioSession.sharedInstance()
        try? s.setCategory(.playback, mode: .default)
        try? s.setActive(true)
    }

    // Transport methods (next/prev/seek/jump/playShuffle/setRepeat) — Task 5.
    // Now-playing + remote commands (configureRemoteCommands/updateNowPlayingInfo) — Task 10.
}
```

> Task 5 and Task 10 add methods referenced above (`next()`, `configureRemoteCommands()`, `updateNowPlayingInfo()`), so **add temporary no-op stubs now so this task compiles**, then flesh them out:
> ```swift
> func next() {}                              // Task 5 replaces
> private func configureRemoteCommands() {}   // Task 10 replaces
> private func updateNowPlayingInfo() {}      // Task 10 replaces
> ```

- [ ] **Step 6: Build, then manually verify on the simulator** (no headless audio assertion)

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3   # ** BUILD SUCCEEDED **
```
This task adds no UI yet (the MiniPlayer is Task 6), so end-to-end play is verified at Task 8. For now: BUILD SUCCEEDED + math/queue tests green is the gate.

- [ ] **Step 7: Run the full unit suite — expect PASS**

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -20
```

- [ ] **Step 8: Commit**

```sh
git add apps/nano-ios/Sources/Playback/PlaybackMath.swift apps/nano-ios/Sources/Playback/AudioEngine.swift apps/nano-ios/Tests/PlaybackMathTests.swift
git commit -m "feat(ios): AudioEngine core — load/play/toggle + sample-time progress"
```

- [ ] **Verify against the handoff:** `04-data-and-sources.md` "Playback / queue state (AudioEngine)" — observable fields (`current`/`isPlaying`/`progress`), `.playback` session, bundled/bookmark resolution on playback, "derive progress from sample time."

---

## Task 5: Transport — next / prev / seek / jump / shuffle / repeat

**Files:**
- Modify: `apps/nano-ios/Sources/Playback/AudioEngine.swift`

- [ ] **Step 1: Replace the `next()` stub and add the transport methods**

Delete the temporary `func next() {}` stub and add (in the "Public API" area):

```swift
    func next() {
        if let t = queue.advance() {
            loadAndStart(t)
        } else {                       // end of queue, repeat off → stop
            player.stop(); stopTicker()
            isPlaying = false; progress = 0; elapsed = 0
            updateNowPlayingInfo()
        }
    }

    func prev() {
        switch queue.goPrev(progress: progress) {
        case .restartCurrent: seek(toFraction: 0)
        case .play(let t):    loadAndStart(t)
        }
    }

    func jump(to i: Int) {
        if let t = queue.jump(to: i) { loadAndStart(t) }
    }

    func playShuffle(_ list: [Track], context: PlayContext) {
        guard !list.isEmpty else { return }
        self.context = context
        let first = Int.random(in: 0..<list.count)
        if let t = queue.loadShuffled(list, firstIndex: first) { loadAndStart(t) }
    }

    func setShuffle(_ on: Bool) { queue.isShuffle = on }   // flag only; reorder happens via playShuffle
    func setRepeat(_ on: Bool) { isRepeat = on }

    func seek(toFraction f: Double) {
        guard let file, totalFrames > 0 else { return }
        let target = AVAudioFramePosition(Double(totalFrames) * min(1, max(0, f)))
        let wasPlaying = isPlaying
        player.stop()
        schedule(file, from: target)
        if wasPlaying { if !engine.isRunning { try? engine.start() }; player.play() }
        updateProgress()
        updateNowPlayingInfo()
    }
```

- [ ] **Step 2: Build — expect SUCCESS**

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Re-run the queue tests** to confirm the engine's use of `PlaybackQueue` didn't change its contract:

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/PlaybackQueueTests 2>&1 | tail -10
```
Expected: PASS (10 tests). Audible behaviour is checked manually at Task 8/11.

- [ ] **Step 4: Commit**

```sh
git add apps/nano-ios/Sources/Playback/AudioEngine.swift
git commit -m "feat(ios): AudioEngine transport — next/prev/seek/jump/shuffle/repeat"
```

- [ ] **Verify against the handoff:** `03-screens.md` Behavior (prev >5% restart, next-at-end stop unless repeat); `04` AudioEngine method list (`next`/`prev`/`seek(toFraction:)`/`jump(to:)`).

---

## Task 6: `MiniPlayer` component

**Files:**
- Create: `apps/nano-ios/Sources/Components/MiniPlayer.swift`

- [ ] **Step 1: Implement `MiniPlayer.swift`** (handoff §02 "Mini player (docked)")

```swift
import SwiftUI

/// Docked mini player (handoff §02): artwork · title/artist · play-pause · next, with a 2pt
/// accent progress bar pinned to the bottom edge. Reads the engine from the environment; only
/// renders when a track is loaded. Body tap is reserved for Now Playing (Phase 4) via `onTapBody`.
/// The optional 56×22 mini-waveform slot (§02) is Phase 3 and omitted here.
struct MiniPlayer: View {
    @Environment(AudioEngine.self) private var engine
    var onTapBody: () -> Void = {}

    var body: some View {
        if let track = engine.current {
            content(track)
        }
    }

    @ViewBuilder
    private func content(_ track: Track) -> some View {
        HStack(spacing: 12) {
            NMArtwork(data: track.artworkData, size: 44, radius: 9)

            VStack(alignment: .leading, spacing: 1) {
                Text(track.title)
                    .font(Theme.sans(14.5, .semibold)).foregroundStyle(Theme.text).lineLimit(1)
                Text(track.artist)
                    .font(Theme.sans(12.5)).foregroundStyle(Theme.text2).lineLimit(1)
            }
            Spacer(minLength: 8)

            Button { engine.toggle() } label: {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18)).foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            Button { engine.next() } label: {
                Image(systemName: "forward.fill")
                    .font(.system(size: 16)).foregroundStyle(Theme.text)
                    .frame(width: 40, height: 40).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, 10).padding(.trailing, 6).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Theme.glassBorder, lineWidth: 0.5)
        )
        .overlay(alignment: .bottom) { progressBar }
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .shadow(color: .black.opacity(0.4), radius: 18, y: 8)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .onTapGesture { onTapBody() }
        .padding(.horizontal, 12)
    }

    private var progressBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.08))
                Rectangle().fill(Theme.accent)
                    .frame(width: geo.size.width * CGFloat(engine.progress))
            }
        }
        .frame(height: 2)
    }
}
```

- [ ] **Step 2: Build — expect SUCCESS** (component not mounted yet; this just compiles it)

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
```

- [ ] **Step 3: Commit**

```sh
git add apps/nano-ios/Sources/Components/MiniPlayer.swift
git commit -m "feat(ios): docked MiniPlayer component"
```

- [ ] **Verify against the handoff:** `02-components.md` "Mini player (docked)" — artwork 44/rad9, title 14.5/600 + artist 12.5/`text2`, play/pause + next as individual hit targets, 2pt accent-over-`white@8%` progress bar, radius 20 `.ultraThinMaterial` + shadow + inset stroke, only present when a track is loaded. (Visual check happens once mounted at Task 7/8 against `Library view with collapsed player.heic`.)

---

## Task 7: Mount the engine + MiniPlayer in `RootView`

**Files:**
- Modify: `apps/nano-ios/Sources/RootView.swift`
- Modify: `apps/nano-ios/Sources/Theme/Theme.swift`

- [ ] **Step 1: Add the playing bottom-pad token** to `Theme.swift`'s `Layout` enum

```swift
        static let scrollBottomPaddingPlaying: CGFloat = 168 // mini player + tab bar (handoff §03)
```

- [ ] **Step 2: Rewrite `RootView.swift`** to own the engine, inject it, and stack the MiniPlayer above the tab bar

```swift
import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .library
    @State private var engine = AudioEngine()

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.bg.ignoresSafeArea()

            Group {
                switch tab {
                case .library:   LibraryScreen(onSearch: { tab = .search })
                case .playlists: PlaylistsScreen()
                case .search:    SearchScreen()
                }
            }

            VStack(spacing: 10) {
                MiniPlayer()                 // renders only when engine.current != nil
                GlassTabBar(selection: $tab)
            }
            .padding(.bottom, 10)
        }
        .environment(engine)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }
}
```

- [ ] **Step 3: Build + launch + screenshot (nothing playing yet → no mini player)**

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
APP="build/Build/Products/Debug-iphonesimulator/NanoMeters.app"
xcrun simctl install F8BC6E09-E5E4-4054-A03B-B1434DF0838D "$APP"
xcrun simctl launch F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios
xcrun simctl io F8BC6E09-E5E4-4054-A03B-B1434DF0838D screenshot /tmp/nano-p2-root.png
```
Read `/tmp/nano-p2-root.png`: Library + glass tab bar unchanged from Phase 1 (mini player absent because nothing is playing). A shifted tab bar means the `VStack` wrapper changed layout — fix before proceeding.

- [ ] **Step 4: Commit**

```sh
git add apps/nano-ios/Sources/RootView.swift apps/nano-ios/Sources/Theme/Theme.swift
git commit -m "feat(ios): own AudioEngine in RootView; dock MiniPlayer above tab bar"
```

- [ ] **Verify against the handoff:** `03-screens.md` global ("glass tab bar floats at the bottom and the mini player docks just above it"). Empty-state must match the Phase 1 Library frame.

---

## Task 8: Wire NMRow tap-to-play + current-track indicator (Library + Search)

**Files:**
- Modify: `apps/nano-ios/Sources/Components/NMRow.swift`
- Modify: `apps/nano-ios/Sources/Screens/LibraryScreen.swift`
- Modify: `apps/nano-ios/Sources/Screens/SearchScreen.swift`

- [ ] **Step 1: Extend `NMRow`** with `isPlaying` + `onTap`, and the current-track artwork overlay (handoff §02: "If this row is the current track, overlay a `black@45%` scrim + a `waveform`(playing) / `play`(paused) glyph, white")

```swift
import SwiftUI

struct NMRow: View {
    let track: Track
    var isCurrent: Bool = false
    var isPlaying: Bool = false
    var onTap: () -> Void = {}
    var onEllipsis: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            NMArtwork(data: track.artworkData, size: 46, radius: Theme.Radius.albumRow)
                .overlay {
                    if isCurrent {
                        ZStack {
                            Color.black.opacity(0.45)
                            Image(systemName: isPlaying ? "waveform" : "play.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.albumRow, style: .continuous))
                    }
                }

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
        .onTapGesture { onTap() }
    }
}
```

- [ ] **Step 2: Wire `LibraryScreen`** — read the engine, pass current/playing flags + the play action, and grow the bottom pad while playing

Add at the top of `LibraryScreen`'s properties:
```swift
    @Environment(AudioEngine.self) private var engine
```
Replace the `ForEach(tracks)` row body:
```swift
                    ForEach(tracks) { track in
                        NMRow(
                            track: track,
                            isCurrent: engine.current?.id == track.id,
                            isPlaying: engine.isPlaying && engine.current?.id == track.id,
                            onTap: { engine.play(track, in: tracks, context: .library) }
                        )
                        Divider().background(Theme.hair).padding(.leading, Theme.Layout.rowSeparatorInset)
                    }
```
Replace the scroll bottom padding line:
```swift
            .padding(.bottom, engine.current == nil ? Theme.Layout.scrollBottomPadding : Theme.Layout.scrollBottomPaddingPlaying)
```

- [ ] **Step 3: Wire `SearchScreen`** identically with the search context + its `results` list

Add `@Environment(AudioEngine.self) private var engine`, replace the `ForEach(results)` row:
```swift
                        ForEach(results) { t in
                            NMRow(
                                track: t,
                                isCurrent: engine.current?.id == t.id,
                                isPlaying: engine.isPlaying && engine.current?.id == t.id,
                                onTap: { engine.play(t, in: results, context: .search) }
                            )
                            Divider().background(Theme.hair).padding(.leading, Theme.Layout.rowSeparatorInset)
                        }
```
and the bottom padding line:
```swift
            .padding(.bottom, engine.current == nil ? Theme.Layout.scrollBottomPadding : Theme.Layout.scrollBottomPaddingPlaying)
```

- [ ] **Step 4: Build, install, and verify play end-to-end with a bundled track**

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
APP="build/Build/Products/Debug-iphonesimulator/NanoMeters.app"
xcrun simctl install F8BC6E09-E5E4-4054-A03B-B1434DF0838D "$APP"
xcrun simctl launch F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios
```
Manual (controller drives the tap, since taps can't be scripted): tap the **Biljam** or **Mercy** row → audio plays; the MiniPlayer docks above the tab bar with title/artist + an advancing progress bar; the row's artwork shows the `waveform` glyph + accent title. Screenshot after the tap and read it:
```sh
xcrun simctl io F8BC6E09-E5E4-4054-A03B-B1434DF0838D screenshot /tmp/nano-p2-playing.png
```
Compare the docked mini player to `Library view with collapsed player.heic`.

- [ ] **Step 5: Run the unit suite — expect PASS**

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -15
```

- [ ] **Step 6: Commit**

```sh
git add apps/nano-ios/Sources/Components/NMRow.swift apps/nano-ios/Sources/Screens/LibraryScreen.swift apps/nano-ios/Sources/Screens/SearchScreen.swift
git commit -m "feat(ios): row tap-to-play + current-track indicator (Library/Search)"
```

- [ ] **Verify against the handoff:** `02-components.md` NMRow (current-track scrim + glyph, accent title, "tapping the row plays the track in the current list context"); `03-screens.md` "Playing from" (Library → All Songs, Search → Search) and the `Library view with collapsed player.heic` frame.

---

## Task 9: Playlist Detail — row taps + Play / Shuffle buttons

**Files:**
- Modify: `apps/nano-ios/Sources/Screens/PlaylistDetailScreen.swift`

- [ ] **Step 1: Read the engine + wire the buttons and rows**

Add to `PlaylistDetailScreen`'s properties:
```swift
    @Environment(AudioEngine.self) private var engine
```
Replace the two `actionButton(...)` calls in the header with real actions:
```swift
                    HStack(spacing: 12) {
                        Button {
                            if let first = tracks.first {
                                engine.play(first, in: tracks, context: .playlist(playlist.name))
                            }
                        } label: { actionButton("play.fill", "Play", filled: true) }
                        .buttonStyle(.plain)
                        .disabled(tracks.isEmpty)

                        Button {
                            engine.playShuffle(tracks, context: .playlist(playlist.name))
                        } label: { actionButton("shuffle", "Shuffle", filled: false) }
                        .buttonStyle(.plain)
                        .disabled(tracks.isEmpty)
                    }
                    .padding(.top, 4)
```
(`actionButton(_:_:filled:)` stays as the label-only view it already is.)

Replace the track `ForEach` with tap-to-play at that row (playlist context, the playlist as queue):
```swift
                ForEach(tracks) { t in
                    NMRow(
                        track: t,
                        isCurrent: engine.current?.id == t.id,
                        isPlaying: engine.isPlaying && engine.current?.id == t.id,
                        onTap: { engine.play(t, in: tracks, context: .playlist(playlist.name)) }
                    )
                }
                .onMove { from, to in LibraryStore.move(in: playlist, fromOffsets: from, toOffset: to) }
                .onDelete { idx in LibraryStore.remove(in: playlist, atOffsets: idx) }
                .listRowBackground(Theme.bg)
```

> Keep `.onMove`/`.onDelete` on this `ForEach`. The row's `onTapGesture` coexists with List editing in `.plain` style.

- [ ] **Step 2: Build + verify**

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
```
Expected `** BUILD SUCCEEDED **`. Manual (controller): make a playlist with the two bundled tracks, open Detail → tap **Play** (starts track 0, context "PLAYING FROM PLAYLIST · {name}") and **Shuffle** (randomized order); tap a row to start mid-list. Confirm the mini player reflects it.

- [ ] **Step 3: Commit**

```sh
git add apps/nano-ios/Sources/Screens/PlaylistDetailScreen.swift
git commit -m "feat(ios): Playlist Detail row tap + Play/Shuffle wired to engine"
```

- [ ] **Verify against the handoff:** `03-screens.md` "C) Playlist Detail" (Play starts at track 0 with playlist context; Shuffle randomizes) and "Playing from" (Playlist → {name}).

---

## Task 10: `MPNowPlayingInfoCenter` + `MPRemoteCommandCenter` + background audio

**Files:**
- Modify: `apps/nano-ios/Sources/Info.plist` (+ `project.yml`)
- Modify: `apps/nano-ios/Sources/Playback/AudioEngine.swift`

- [ ] **Step 1: Declare the audio background mode** in `Info.plist`

```xml
	<key>UIBackgroundModes</key>
	<array>
		<string>audio</string>
	</array>
```
And mirror in `project.yml` under `info: properties:`:
```yaml
        UIBackgroundModes: [audio]
```

- [ ] **Step 2: Replace the Task-4 stubs** in `AudioEngine.swift`

Add `import MediaPlayer` and `import UIKit` at the top. Delete the temporary `configureRemoteCommands`/`updateNowPlayingInfo` no-op stubs and add:

```swift
    private func configureRemoteCommands() {
        let c = MPRemoteCommandCenter.shared()
        c.playCommand.addTarget { [weak self] _ in self?.resume(); return .success }
        c.pauseCommand.addTarget { [weak self] _ in self?.pausePlayback(); return .success }
        c.togglePlayPauseCommand.addTarget { [weak self] _ in self?.toggle(); return .success }
        c.nextTrackCommand.addTarget { [weak self] _ in self?.next(); return .success }
        c.previousTrackCommand.addTarget { [weak self] _ in self?.prev(); return .success }
        c.changePlaybackPositionCommand.addTarget { [weak self] event in
            guard let self,
                  let e = event as? MPChangePlaybackPositionCommandEvent,
                  self.totalFrames > 0, self.sampleRate > 0 else { return .commandFailed }
            self.seek(toFraction: e.positionTime * self.sampleRate / Double(self.totalFrames))
            return .success
        }
    }

    private func resume() { if !isPlaying { toggle() } }
    private func pausePlayback() { if isPlaying { toggle() } }

    private func updateNowPlayingInfo() {
        let center = MPNowPlayingInfoCenter.default()
        guard let t = current else { center.nowPlayingInfo = nil; return }
        let duration = totalFrames > 0 && sampleRate > 0 ? Double(totalFrames) / sampleRate : t.durationSec
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: t.title,
            MPMediaItemPropertyArtist: t.artist,
            MPMediaItemPropertyAlbumTitle: t.album,
            MPMediaItemPropertyPlaybackDuration: duration,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        if let data = t.artworkData, let img = UIImage(data: data) {
            info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in img }
        }
        center.nowPlayingInfo = info
    }
```

- [ ] **Step 3: Keep the now-playing elapsed roughly fresh** — in `updateProgress()`, refresh once a second (the ticker runs at 20 Hz):

```swift
    func updateProgress() {
        progress = PlaybackMath.fraction(frame: currentFrame, total: totalFrames)
        elapsed = sampleRate > 0 ? Double(currentFrame) / sampleRate : 0
        if Int(elapsed * 20) % 20 == 0 { updateNowPlayingInfo() }
    }
```

- [ ] **Step 4: Build, install, verify on lock screen / control center**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
/usr/libexec/PlistBuddy -c "Print :UIBackgroundModes:0" "build/Build/Products/Debug-iphonesimulator/NanoMeters.app/Info.plist"  # → audio
APP="build/Build/Products/Debug-iphonesimulator/NanoMeters.app"
xcrun simctl install F8BC6E09-E5E4-4054-A03B-B1434DF0838D "$APP"
xcrun simctl launch F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios
```
`UIBackgroundModes:0` must print `audio`. Manual: play a track, open Control Center in the sim → the now-playing card shows title/artist + transport; play/pause/next/prev there drive the engine.

- [ ] **Step 5: Full unit suite — expect PASS**

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -15
```

- [ ] **Step 6: Commit**

```sh
git add apps/nano-ios/Sources/Info.plist apps/nano-ios/project.yml apps/nano-ios/Sources/Playback/AudioEngine.swift
git commit -m "feat(ios): now-playing info + remote commands + background audio"
```

- [ ] **Verify against the handoff:** `04-data-and-sources.md` AudioEngine bullets — "Wire `MPRemoteCommandCenter` (play/pause/next/prev/seek) and keep `MPNowPlayingInfoCenter…nowPlayingInfo` updated … so lock screen / AirPods / CarPlay work. Configure `AVAudioSession` `.playback` and the Audio background mode."

---

## Task 11: Final integration review + simulator walkthrough

**Files:** none (review/verification)

- [ ] **Step 1: Clean build + full test suite on iOS 26.5**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -25
```
Expected: all suites pass (Smoke, Theme, LibraryStore, Import, DemoSeed, Search, **PlaybackQueue**, **PlaybackMath**).

- [ ] **Step 2: End-to-end manual walkthrough** (the two bundled tracks are seeded on first launch):
  - Tap **Biljam** / **Mercy** in Library → plays; mini player docks with advancing progress; row shows accent title + `waveform` glyph.
  - Mini player **play/pause** toggles audio + glyph; **next** advances; progress bar tracks.
  - Let a track end → auto-advances; at queue end with repeat off → stops.
  - Search → tap result plays with Search context.
  - Playlist Detail → **Play** (track 0), **Shuffle** (randomized), tap a row mid-list.
  - Control Center transport drives the engine.
  - (Optional) Import one of your own tracks (folder button) and confirm it plays the same way.

- [ ] **Step 3: Verify the whole phase against the handoff** — re-read §02 Mini player + NMRow, §03 Playlist Detail + "Playing from" + global mini-dock, §04 AudioEngine, and the `Library view with collapsed player.heic` frame. Note any drift; fix or flag.

- [ ] **Step 4: Confirm a clean tree and the commit chain**

```sh
git -C /Users/wasp/Developer/nanometers/.claude/worktrees/nano-ios status --short
git -C /Users/wasp/Developer/nanometers/.claude/worktrees/nano-ios log --oneline main..HEAD
```

---

## Self-Review (run before execution)

**Spec coverage** (Phase 2 = "local playback: `AudioEngine`, transport, queue/context, sample-time progress, `MPNowPlayingInfoCenter` / remote commands, `MiniPlayer`"):
- AudioEngine → Tasks 4–5, 10. ✓
- Transport (next/prev/repeat/shuffle, prev-restart threshold) → Task 3 (pure + tested) + Task 5 (wired). ✓
- Queue / context → Tasks 3, 8, 9 (`PlayContext` set per screen). ✓
- Sample-time progress → Task 4 (`currentFrame` from `playerTime.sampleTime`; `PlaybackMath.fraction`). ✓
- `MPNowPlayingInfoCenter` / remote → Task 10. ✓
- MiniPlayer → Tasks 6–7. ✓
- Spec testing line ("AudioEngine queue logic: next/prev/repeat, prev-restart-threshold") → Task 3's `PlaybackQueueTests`. ✓
- Bundled playable demo content → Task 2 (also keeps the art-fallback demonstration). ✓

**Placeholder scan:** all code blocks concrete; the only intentional stubs are the Task-4 no-ops explicitly replaced in Tasks 5 & 10, and the MiniPlayer `onTapBody` no-op (Now Playing is Phase 4, in scope notes). ✓

**Type consistency:** `PlayContext` is the single context type used by `play`/`playShuffle`/screens; `PlaybackQueue.PrevAction` (`.restartCurrent`/`.play`) consumed by `AudioEngine.prev()`; `Track.bundledName` set in Task 2, read in Task 4's `resolveURL`; `loadAndStart`/`schedule`/`handlePlaybackEnded(token:)`/`updateProgress` names match across Tasks 4/5/10; `scrollBottomPaddingPlaying` defined in Task 7 and read in Tasks 8/9. ✓

**Deferred-scope honesty:** no Now Playing screen, no waveforms/LUFS, no nano-dsp link, no queue sheet — all flagged. ✓
