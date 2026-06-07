# Nanometers iOS — Phase 4: Now Playing + Transition Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Tapping the mini player morphs (via `matchedGeometryEffect`) into a full-screen Now Playing surface — artwork-tint gradient, transport, volume, the re-homed overview scrubber + integrated-LUFS badge, a bottom rail, the Settings sheet (`@AppStorage`), and the local bottom sheets (context menu, add-to-playlist, queue).

**Architecture:** Now Playing is an **in-tree `ZStack` overlay in `RootView`** (NOT `.fullScreenCover`/`.sheet`) so a shared `@Namespace` lets the mini player's 44pt artwork morph into the hero — a cover/sheet boundary would silently break the morph. A standalone `ArtworkTintStore` (mirroring `WaveformStore`) extracts a 1×1 average tint once per track and caches it on `Track.artworkTintHex`. The three waveform display prefs live in `@AppStorage` (set only in Settings) and are the single source of truth for what Now Playing renders. `AudioEngine` gains a player-gain `volume` API and a real `toggleShuffle`. The interim `TrackDetailScreen` is retired and `OverviewWaveform` is re-homed unchanged.

**Tech Stack:** SwiftUI (`matchedGeometryEffect`, `@Namespace`, `@AppStorage`, `TimelineView`/spring animation, `.presentationDetents`), CoreImage (`CIAreaAverage`) for the tint, `AVRoutePickerView` (AirPlay), the existing `AudioEngine`/`WaveformStore`/`OverviewWaveform`. iOS 17+, **Apple-silicon simulator**. Built/tested on the **iOS 26.5 iPhone 17 Pro** sim, UDID `F8BC6E09-E5E4-4054-A03B-B1434DF0838D`.

---

## Design handoff — the canonical source, verify against it

Locked design: **`/Users/wasp/Downloads/design_handoff_nanometers/`**. Don't restate its numbers from this plan as truth — open it and confirm. Phase 4 touches:

- **`03-screens.md`** — `## D) Now Playing` (the full top→bottom layout + all behaviors) and `## Bottom sheets` (1 context menu, 4 add-to-playlist, 6 Settings, 7 queue) + `## "Playing from" context`.
- **`02-components.md`** — `## Buttons` (glass round / primary / secondary / sheet action rows), `## iOS switch + Settings rows` (IOSSwitch → `Toggle.tint(accent)`, SettingsRow, SettingsGroup), the Icons SF-symbol table, the `matchedGeometryEffect` note on NMArtwork, `## NMLufs` (the badge capsule).
- **`01-design-tokens.md`** — the gradient stops, motion easing/durations, hero radius.
- **`design_reference/screens-now.jsx`** (NP + sheets layout/behaviors) and **`tweaks-panel.jsx`** (the 3 toggles) — behaviour reference, not API.

Each UI/behaviour task ends with **"Verify against the handoff"** naming the section/`.jsx` lines. The handoff wins; fix code + flag the plan on conflict.

---

## Gotchas (from the Phase 4 research — read before starting)

1. **`matchedGeometryEffect` cannot cross a `.fullScreenCover`/`.sheet` boundary** — that content is a separate `UIHostingController`, so the RootView `@Namespace` never reaches it and the morph silently degrades to a pop/cross-fade. Now Playing MUST be an **in-`ZStack` overlay** in RootView. Highest-risk decision; the prototype (`screens-now.jsx:265-271`, a `translateY` overlay) corroborates it.
2. **Keep `MiniPlayer` mounted under the overlay.** It's conditionally mounted (`if engine.current != nil`, `MiniPlayer.swift:14`). Do NOT also gate it on `!npOpen` — if the matched view is torn down at the instant `npOpen` flips, the morph glitches. It stays because `current` is non-nil throughout.
3. **The tint fallback IS the first-run state.** `Track.artworkTintHex` is written nowhere today (always nil) and there's no `Color(hex: String)` parser yet; both bundled demo tracks have **no artwork** (`DemoSeed.swift`). So the no-art fallback (`Theme.bgElev2` top stop) is what you'll see on launch — make it look right, not flat.
4. **`AudioEngine.setShuffle` is flag-only** — it does NOT reorder the live queue (reorder happens in `playShuffle`/`loadShuffled`). The Now Playing shuffle button needs a new `toggleShuffle()` that reshuffles the remaining queue, or it appears inert mid-playback.
5. **Volume = player gain, not system volume.** `player.volume` (AVAudioPlayerNode) moves only the player node, not the iOS hardware/lock-screen HUD. Spec-sanctioned (`§03D` item 9 "player gain node"). MPVolumeView would be a larger, different-UX change — out of scope.
6. **Delete `TrackDetailScreen` only AFTER Now Playing renders the overview.** Retiring it removes the only current route to the scrubber (the replacing context sheet does NOT contain it — it moved to Now Playing). Sequence the deletion last (Task 7) or Phase-3's overview visibly regresses.
7. **Now Playing side padding is 26pt** (`screens-now.jsx:292`), NOT `Theme.Layout.screenMargin` (20pt).
8. **The 76pt play/pause glyph is drawn in `Theme.bg` (#15171E, dark-on-amber)**, not white.
9. **XCUITest dismiss: use the `chevron.down` button** (deterministic) as the primary teardown assertion; synthetic swipe-down can miss the >80pt threshold (secondary).
10. **Add-to-Playlist is a NEW component.** The existing `AddSongsSheet` (`PlaylistDetailScreen.swift`, `private`) edits one playlist's membership (playlist→tracks) — the inverse of the context flow (track→playlists).

**Adopted defaults (the three open questions):** volume = in-app player gain; `@AppStorage` defaults `showWave=true`, `spectrum=false`, `zoomWave=false` (Close-up is Phase 5); tint = 1×1 `CIAreaAverage` (no dominant-color algorithm in v1).

---

## File Structure

New:

| File | Responsibility |
|---|---|
| `Sources/Screens/NowPlayingScreen.swift` | The full Now Playing surface (built up across Tasks 2/4/5/6/7/8). |
| `Sources/DSP/ArtworkTintStore.swift` | `@MainActor @Observable` singleton: once-per-track 1×1 `CIAreaAverage` from `artworkData` off-main, caches `Track.artworkTintHex`, returns a `Color` (or `Theme.bgElev2` fallback). |
| `Sources/Screens/SettingsSheet.swift` | `.insetGrouped` Form, "Waveform Display" group: 3 `Toggle`s → `@AppStorage` (`zoomWave`/`showWave`/`spectrum`), the disable-when-both-off rule. |
| `Sources/Screens/TrackContextSheet.swift` | Track context menu (artwork-52 header) — local actions: Play Next, Add to Queue, Add to Playlist…, Love. |
| `Sources/Screens/AddToPlaylistSheet.swift` | track→playlists membership toggle (new; inverse of `AddSongsSheet`). |
| `Sources/Screens/QueueSheet.swift` | Up Next list from `engine.queue`; tap → `engine.jump(to:)`. |
| `Sources/Components/AirPlayButton.swift` | `UIViewRepresentable` over `AVRoutePickerView`. |
| `Sources/Components/LUFSBadge.swift` | Glass-capsule `[S][value][LUFS]` badge (§02 NMLufs, value 13pt); shows the integrated LUFS in Phase 4. |
| `Tests/ThemeTests.swift` (modify) | `Color(hex: String)` parse tests. |
| `Tests/ArtworkTintStoreTests.swift` | average-hex of a known solid image. |
| `UITests/NowPlayingUITests.swift` | present → assert → dismiss; settings toggle hides the overview. |

Modified: `Sources/RootView.swift` (namespace + overlay + tab-bar hide), `Sources/Components/MiniPlayer.swift` (namespace param + matchedGeometry + real `onTapBody`), `Sources/Playback/AudioEngine.swift` (`volume`/`setVolume`/`toggleShuffle`), `Sources/Theme/Theme.swift` (`Color(hex:String)`, gradient tokens, hero radius), `Sources/Screens/LibraryScreen.swift` + `PlaylistDetailScreen.swift` (gear→Settings, ellipsis→context sheet), **delete** `Sources/Screens/TrackDetailScreen.swift`.

---

## Scope

**In:** Now Playing full screen + matched-geometry present/dismiss + tab-bar hide; artwork-tint gradient; transport (shuffle/prev/play-pause/next/repeat) + a real `toggleShuffle`; player-gain volume row; re-homed `OverviewWaveform` scrubber (Settings-gated) + integrated-LUFS badge + time row; Settings sheet (`@AppStorage`); context-menu / add-to-playlist / queue sheets; bottom rail (folder stub · AirPlay · queue); Reduce-Motion degrade.

**Deferred (do NOT build here):** the **Close-up DJ scroll (`NMScrollWave`)** + the **live short-term LUFS meter (`nano_meter_*`)** → **Phase 5** (the badge shows the *integrated* value now; only the value source changes in Phase 5). **Sources hub / Source Folder peek / cloud** (and the context actions "Go to Source Folder" / "Remove Download") → **v2**.

**Out of scope:** anything not in the handoff; iPad; landscape; MPVolumeView/system volume.

---

## Task 1: Theme — `Color(hex: String)`, gradient stops, hero radius

**Files:** Modify `Sources/Theme/Theme.swift`, `Tests/ThemeTests.swift`.

- [ ] **Step 1: Write the failing test** — append to `Tests/ThemeTests.swift` (it already tests `Color(hex: UInt32)`):

```swift
    func test_colorFromHexStringMatchesIntLiteral() {
        XCTAssertEqual(Color(hex: "#14161C"), Color(hex: 0x14161C))
        XCTAssertEqual(Color(hex: "111319"), Color(hex: 0x111319))   // leading # optional
    }
    func test_colorFromBadHexFallsBackToClear() {
        XCTAssertEqual(Color(hex: "nope"), Color.clear)
    }
```

- [ ] **Step 2: Run — expect FAIL** (`Color(hex: String)` not found):

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/ThemeTests 2>&1 | tail -15
```

- [ ] **Step 3: Implement.** In `Theme.swift`, add the gradient/radius tokens (in `Theme` and `Theme.Radius`):

```swift
    // Now Playing gradient stops (§01 / §03D background).
    static let npGradientMid    = Color(hex: 0x14161C)
    static let npGradientBottom = Color(hex: 0x111319)
```
```swift
        static let albumNowPlaying: CGFloat = 18   // §03D artwork hero
```
And add a `String` hex initializer in the existing `extension Color`:

```swift
    /// "#RRGGBB" (or "RRGGBB") → Color; `.clear` on malformed input. Used by the artwork-tint cache.
    init(hex string: String) {
        let s = string.hasPrefix("#") ? String(string.dropFirst()) : string
        guard s.count == 6, let v = UInt32(s, radix: 16) else { self = .clear; return }
        self.init(hex: v)
    }
```

- [ ] **Step 4: Run — expect PASS.** Then commit:

```sh
git add apps/nano-ios/Sources/Theme/Theme.swift apps/nano-ios/Tests/ThemeTests.swift
git commit -m "feat(ios): Theme — Color(hex:String) + Now Playing gradient/radius tokens"
```

- [ ] **Verify against the handoff:** `01-design-tokens.md` (gradient stops #14161C/#111319; hero radius 18).

---

## Task 2: Present/transition — mini-player tap morphs into the Now Playing overlay; tab bar hides

**Files:** Modify `Sources/RootView.swift`, `Sources/Components/MiniPlayer.swift`; Create `Sources/Screens/NowPlayingScreen.swift`, `UITests/NowPlayingUITests.swift`.

- [ ] **Step 1: Add the namespace param + matched artwork to `MiniPlayer`.** In `MiniPlayer.swift`, add a property:

```swift
    var namespace: Namespace.ID
```
and attach the matched effect to the 44pt artwork (the `NMArtwork(data: track.artworkData, size: 44, radius: 9)` line):

```swift
            NMArtwork(data: track.artworkData, size: 44, radius: 9)
                .matchedGeometryEffect(id: "artwork-\(track.id)", in: namespace)
```
(`onTapBody` already exists and is invoked on body tap — RootView will now pass a real closure.)

- [ ] **Step 2: Create a minimal `Sources/Screens/NowPlayingScreen.swift`** (scaffold + hero + dismiss; sections filled by later tasks):

```swift
import SwiftUI

/// Full-screen Now Playing surface, presented as an in-tree overlay from RootView (NOT a cover —
/// matchedGeometryEffect can't cross a cover/sheet boundary). Sections are built up across Phase 4
/// tasks. The hero artwork morphs from the mini player's 44pt tile via the shared namespace.
struct NowPlayingScreen: View {
    @Environment(AudioEngine.self) private var engine
    var namespace: Namespace.ID
    var onClose: () -> Void

    var body: some View {
        ZStack {
            Theme.npGradientBottom.ignoresSafeArea()   // Task 3 swaps this for the tint gradient

            VStack(spacing: 18) {
                topBar
                Spacer(minLength: 8)
                hero
                Spacer(minLength: 8)
                // Task 4 title row · Task 7 scrubber+time · Task 5 transport · Task 6 volume · Task 9 bottom rail
            }
            .padding(.horizontal, 26)                  // §03D side padding (NOT screenMargin)
            .padding(.top, 8).padding(.bottom, 28)
        }
        .accessibilityIdentifier("nowPlaying")
        .contentShape(Rectangle())
        .gesture(DragGesture().onEnded { if $0.translation.height > 80 { onClose() } })
    }

    @ViewBuilder private var topBar: some View {
        HStack {
            Button(action: onClose) {
                Image(systemName: "chevron.down").font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.text).frame(width: 44, height: 44)
            }
            .accessibilityIdentifier("npDismiss")
            Spacer()
            // Task 4 fills the centered context label + ellipsis
        }
    }

    @ViewBuilder private var hero: some View {
        if let track = engine.current {
            NMArtwork(data: track.artworkData, size: 340, radius: Theme.Radius.albumNowPlaying)   // §03D ≤340 cap
                .matchedGeometryEffect(id: "artwork-\(track.id)", in: namespace)
                .shadow(color: .black.opacity(0.45), radius: 30, y: 10)   // §01 layered drop shadow…
                .shadow(color: .black.opacity(0.3), radius: 8, y: 2)      // …+ the softer near layer
                .scaleEffect(engine.isPlaying ? 1.0 : 0.86)   // §03D scale (Task 10 gates on Reduce Motion)
                .animation(.spring(response: 0.5, dampingFraction: 0.86), value: engine.isPlaying)  // §01 cubic-bezier(.32,.72,0,1) ≈ this spring
        }
    }
}
```

- [ ] **Step 3: Wire `RootView`** — own the namespace + present state, pass them down, render the overlay, hide the tab bar. Rewrite `RootView.swift`:

```swift
import SwiftUI

struct RootView: View {
    @State private var tab: Tab = .library
    @State private var engine = AudioEngine()
    @State private var npOpen = false
    @Namespace private var heroNS

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
                MiniPlayer(namespace: heroNS, onTapBody: { open() })
                GlassTabBar(selection: $tab)
            }
            .padding(.bottom, 10)
            .offset(y: npOpen ? 220 : 0)             // slide the dock + tab bar away (≈translateY 140%)
            .opacity(npOpen ? 0 : 1)
            .animation(.spring(response: 0.4, dampingFraction: 0.9), value: npOpen)   // §01 tab-bar hide is 0.4s, distinct from the 0.5s present

            if npOpen, engine.current != nil {
                NowPlayingScreen(namespace: heroNS, onClose: { close() })
                    .transition(.move(edge: .bottom))
                    .zIndex(1)
            }
        }
        .environment(engine)
        .preferredColorScheme(.dark)
        .tint(Theme.accent)
    }

    private func open()  { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { npOpen = true } }
    private func close() { withAnimation(.spring(response: 0.5, dampingFraction: 0.86)) { npOpen = false } }
}
```

- [ ] **Step 4: Create the failing UI test** `UITests/NowPlayingUITests.swift`:

```swift
import XCTest

final class NowPlayingUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_miniPlayerTapPresentsAndChevronDismissesNowPlaying() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 10))
        app.staticTexts["Mercy"].tap()                       // dock the mini player

        app.staticTexts["miniPlayerTitle"].tap()             // tap mini body → present NP
        let np = app.otherElements["nowPlaying"]
        XCTAssertTrue(np.waitForExistence(timeout: 5), "Now Playing should present")

        app.buttons["npDismiss"].tap()                       // chevron.down dismiss (deterministic)
        XCTAssertFalse(np.waitForExistence(timeout: 3), "Now Playing should dismiss")
    }
}
```

- [ ] **Step 5: Regenerate, build, run the UI test + screenshot the morph:**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersUITests/NowPlayingUITests 2>&1 | tail -20
```
Expected PASS. (Manual: also screenshot mid/after-present to eyeball the artwork morph + tab bar sliding away.)

> Note: tapping `miniPlayerTitle` lands inside the mini player body whose `.onTapGesture { onTapBody() }` presents NP. The play/pause/next buttons stop propagation (separate hit targets), so they won't present.

- [ ] **Step 6: Commit**

```sh
git add apps/nano-ios/Sources/RootView.swift apps/nano-ios/Sources/Components/MiniPlayer.swift \
  apps/nano-ios/Sources/Screens/NowPlayingScreen.swift apps/nano-ios/UITests/NowPlayingUITests.swift
git commit -m "feat(ios): present Now Playing as a matched-geometry overlay; hide tab bar"
```

- [ ] **Verify against the handoff:** `03-screens.md` §D presentation (tap mini → present; chevron/swipe dismiss; tab bar hides); `01-design-tokens.md` motion (spring ≈0.5s); `screens-now.jsx:264-271` (overlay, not a cover).

---

## Task 3: Artwork-tint extraction + gradient background

**Files:** Create `Sources/DSP/ArtworkTintStore.swift`, `Tests/ArtworkTintStoreTests.swift`; Modify `Sources/Screens/NowPlayingScreen.swift`.

- [ ] **Step 1: Write the failing test** `Tests/ArtworkTintStoreTests.swift`:

```swift
import XCTest
import UIKit
@testable import NanoMeters

final class ArtworkTintStoreTests: XCTestCase {
    func test_averageHexOfSolidImageMatches() {
        // A 4×4 solid orange PNG → average ≈ that color.
        let size = CGSize(width: 4, height: 4)
        UIGraphicsBeginImageContext(size)
        UIColor(red: 0.94, green: 0.66, blue: 0.41, alpha: 1).setFill()
        UIRectFill(CGRect(origin: .zero, size: size))
        let img = UIGraphicsGetImageFromCurrentImageContext()!
        UIGraphicsEndImageContext()
        let data = img.pngData()!

        let hex = ArtworkTintStore.averageHex(data)
        XCTAssertNotNil(hex)
        XCTAssertEqual(hex?.first, "#")
        // Roughly EFA869-ish; assert the red channel dominates (≈0xEF).
        let r = UInt8(hex!.dropFirst().prefix(2), radix: 16) ?? 0
        XCTAssertGreaterThan(r, 0xD0)
    }
    func test_averageHexOfGarbageIsNil() {
        XCTAssertNil(ArtworkTintStore.averageHex(Data([0, 1, 2, 3])))
    }
}
```

- [ ] **Step 2: Run — expect FAIL.** (`xcodegen generate` first.)

- [ ] **Step 3: Implement `Sources/DSP/ArtworkTintStore.swift`:**

```swift
import SwiftUI
import CoreImage
import UIKit
import SwiftData

/// Extracts a track's dominant tint (1×1 area-average of its embedded artwork) once, caches the hex
/// on `Track.artworkTintHex`, and serves it as a `Color`. Mirrors `WaveformStore`'s once-per-track +
/// inflight-dedupe shape. No artwork → `Theme.bgElev2` (the neutral first-run case; demo tracks have
/// no art). The CoreImage work runs off the main actor.
@MainActor
@Observable
final class ArtworkTintStore {
    static let shared = ArtworkTintStore()
    private var inflight: Set<PersistentIdentifier> = []

    /// The gradient top-stop color for `track`. Cache hit → parse; miss → extract + persist; no art → fallback.
    func tint(for track: Track) async -> Color {
        if let hex = track.artworkTintHex { return Color(hex: hex) }
        guard let data = track.artworkData else { return Theme.bgElev2 }

        let id = track.persistentModelID
        guard !inflight.contains(id) else { return Theme.bgElev2 }
        inflight.insert(id); defer { inflight.remove(id) }

        guard let hex = await Task.detached(priority: .utility, operation: { Self.averageHex(data) }).value else {
            return Theme.bgElev2
        }
        track.artworkTintHex = hex
        return Color(hex: hex)
    }

    /// Nonisolated 1×1 CIAreaAverage → "#RRGGBB" (nil on undecodable data). Safe to call off-main.
    nonisolated static func averageHex(_ data: Data) -> String? {
        guard let ui = UIImage(data: data), let cg = ui.cgImage else { return nil }
        let input = CIImage(cgImage: cg)
        guard let filter = CIFilter(name: "CIAreaAverage",
                                    parameters: [kCIInputImageKey: input,
                                                 kCIInputExtentKey: CIVector(cgRect: input.extent)]),
              let output = filter.outputImage else { return nil }
        var px = [UInt8](repeating: 0, count: 4)
        let ctx = CIContext(options: [.workingColorSpace: NSNull()])
        ctx.render(output, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        return String(format: "#%02X%02X%02X", px[0], px[1], px[2])
    }
}
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Use it in `NowPlayingScreen`** — replace the placeholder background with the tint gradient + a faint glass scrim, loaded in a `.task`. Add a state var:

```swift
    @State private var tint: Color = Theme.bgElev2
```
Replace `Theme.npGradientBottom.ignoresSafeArea()` (from Task 2) with:

```swift
            LinearGradient(stops: [.init(color: tint, location: 0),
                                   .init(color: Theme.npGradientMid, location: 0.46),
                                   .init(color: Theme.npGradientBottom, location: 1)],
                           startPoint: .top, endPoint: .bottom)
                .overlay {                                   // §03D faint glass scrim (system material per §01, not hand-rolled blur)
                    ZStack {
                        Rectangle().fill(.ultraThinMaterial).opacity(0.18)
                        Theme.npGradientBottom.opacity(0.35)     // #111319 @ 0.35
                    }.allowsHitTesting(false)
                }
                .ignoresSafeArea()
```
And add the load alongside the screen's other modifiers (e.g. after `.accessibilityIdentifier("nowPlaying")`):

```swift
        .task(id: engine.current?.persistentModelID) {
            if let t = engine.current { tint = await ArtworkTintStore.shared.tint(for: t) }
        }
```

- [ ] **Step 6: Build, install, screenshot Now Playing** (present a track, confirm the gradient — neutral `#232732`→`#14161C`→`#111319` for the art-less demo tracks, not flat):

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' -derivedDataPath build build 2>&1 | tail -3
```
(Full present-and-screenshot is exercised by `NowPlayingUITests`; the build + tint unit test are the gate here.)

- [ ] **Step 7: Full unit suite — expect PASS. Commit:**

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | grep -E "Executed [0-9]+ test|\*\* TEST" | tail -4
git add apps/nano-ios/Sources/DSP/ArtworkTintStore.swift apps/nano-ios/Tests/ArtworkTintStoreTests.swift apps/nano-ios/Sources/Screens/NowPlayingScreen.swift
git commit -m "feat(ios): artwork-tint gradient on Now Playing (cached, no-art fallback)"
```

- [ ] **Verify against the handoff:** `03-screens.md` §D background (artwork-tint → #14161C → #111319 + glass scrim); `02-components.md` ("extract once, cache on the Track").

---

## Task 4: Top bar (context label + ellipsis) + title row + heart

**Files:** Modify `Sources/Screens/NowPlayingScreen.swift`.

- [ ] **Step 1: Fill the top bar's center + trailing** and add the title row. Replace the `topBar` body's `Spacer()` + trailing comment with the centered context + ellipsis, and add a `titleRow` after the hero. Add a sheet state:

```swift
    @State private var showContext = false
```
`topBar`:

```swift
    @ViewBuilder private var topBar: some View {
        ZStack {
            VStack(spacing: 1) {
                Text(engine.context.kind)
                    .font(Theme.sans(10.5, .bold)).tracking(1.4).foregroundStyle(.white.opacity(0.5))
                Text(engine.context.name)
                    .font(Theme.sans(13, .semibold)).foregroundStyle(Theme.text)
            }
            HStack {
                Button(action: onClose) {
                    Image(systemName: "chevron.down").font(.system(size: 26, weight: .semibold))
                        .foregroundStyle(Theme.text).frame(width: 44, height: 44)
                }.accessibilityIdentifier("npDismiss")
                Spacer()
                Button { showContext = true } label: {
                    Image(systemName: "ellipsis").font(.system(size: 24))
                        .foregroundStyle(Theme.text).frame(width: 44, height: 44)
                }.accessibilityIdentifier("npEllipsis")
            }
        }
    }
```
Add the `titleRow` (insert into the main `VStack` after the lower `Spacer`):

```swift
    @ViewBuilder private var titleRow: some View {
        if let track = engine.current {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(track.title).font(Theme.sans(22, .bold)).tracking(-0.3).foregroundStyle(Theme.text).lineLimit(1)
                    Text(track.artist).font(Theme.sans(17)).foregroundStyle(.white.opacity(0.62)).lineLimit(1)
                }
                Spacer(minLength: 8)
                Button { track.isLoved.toggle() } label: {
                    Image(systemName: track.isLoved ? "heart.fill" : "heart")
                        .font(.system(size: 24)).foregroundStyle(track.isLoved ? Theme.accent : Theme.text)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain).accessibilityIdentifier("npHeart")
            }
        }
    }
```
Wire `titleRow` into the `VStack` (after the hero `Spacer`), and present the context sheet (Task 9 builds `TrackContextSheet`; for now stub it so this compiles):

```swift
                titleRow
```
```swift
        .sheet(isPresented: $showContext) {
            if let t = engine.current { TrackContextSheet(track: t) }
        }
```
> If `TrackContextSheet` doesn't exist yet, add a temporary stub `struct TrackContextSheet: View { let track: Track; var body: some View { Text(track.title) } }` at the bottom of this file and DELETE it in Task 9 when the real one lands. (Report this stub.)

- [ ] **Step 2: Build + screenshot.** Present Now Playing; confirm the context label ("PLAYING FROM LIBRARY" / "All Songs"), title/artist, and a tappable heart.

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' -derivedDataPath build build 2>&1 | tail -3
```

- [ ] **Step 3: Commit**

```sh
git add apps/nano-ios/Sources/Screens/NowPlayingScreen.swift
git commit -m "feat(ios): Now Playing top bar (context + ellipsis) + title row + heart"
```

- [ ] **Verify against the handoff:** `03-screens.md` §D items 1 & 3 (context label 10.5/700 tracking 1.4 white@50% + name 13/600; title 22/700 + artist 17/white@62%; heart fills accent when loved, **persists** — `track.isLoved` is SwiftData-backed, not ephemeral); `screens-now.jsx:276-300`.

---

## Task 5: Transport row + real `toggleShuffle`

**Files:** Modify `Sources/Playback/AudioEngine.swift`, `Sources/Screens/NowPlayingScreen.swift`, `Tests/PlaybackQueueTests.swift`.

- [ ] **Step 1: Write the failing test** for a reshuffle-in-place on the queue. Append to `Tests/PlaybackQueueTests.swift`:

```swift
    func test_reshuffleKeepsCurrentAndShufflesRest() throws {
        let ts = try tracks(6)
        var q = PlaybackQueue(); _ = q.load(ts, startingAt: 2)
        let current = q.current
        q.reshuffleRemaining()
        XCTAssertEqual(q.current?.id, current?.id, "current track stays put")
        XCTAssertTrue(q.isShuffle)
        XCTAssertEqual(Set(q.tracks.map(\.id)).count, 6, "no tracks lost")
    }
```

- [ ] **Step 2: Run — expect FAIL** (`reshuffleRemaining` missing).

- [ ] **Step 3: Implement `reshuffleRemaining` on `PlaybackQueue`** (`Sources/Playback/PlaybackQueue.swift`):

```swift
    /// Shuffle the tracks AFTER the current one in place (current stays at its index). Sets shuffle.
    mutating func reshuffleRemaining() {
        guard tracks.indices.contains(index) else { isShuffle = true; return }
        let head = Array(tracks[...index])
        var tail = Array(tracks[(index + 1)...])
        tail.shuffle()
        tracks = head + tail
        isShuffle = true
    }
```
And add `toggleShuffle()` to `AudioEngine` (`Sources/Playback/AudioEngine.swift`) — replace the flag-only `setShuffle`'s role for the NP button:

```swift
    func toggleShuffle() {
        if queue.isShuffle { queue.isShuffle = false }
        else { queue.reshuffleRemaining() }
    }
```
(Keep `setShuffle`/`setRepeat`; `toggleShuffle` is what the Now Playing button calls.)

- [ ] **Step 4: Run the queue tests — expect PASS.**

- [ ] **Step 5: Add the transport row** to `NowPlayingScreen` (insert into the main `VStack`, below where the scrubber will go in Task 7 — for now after `titleRow`):

```swift
    @ViewBuilder private var transportRow: some View {
        HStack {
            Button { engine.toggleShuffle() } label: {
                Image(systemName: "shuffle").font(.system(size: 22))
                    .foregroundStyle(engine.isShuffle ? Theme.accent : .white.opacity(0.85))
            }.buttonStyle(.plain).frame(maxWidth: .infinity)

            Button { engine.prev() } label: {
                Image(systemName: "backward.fill").font(.system(size: 34)).foregroundStyle(Theme.text)
            }.buttonStyle(.plain).frame(maxWidth: .infinity)

            Button { engine.toggle() } label: {
                ZStack {
                    Circle().fill(Theme.accent).frame(width: 76, height: 76)
                        .shadow(color: .black.opacity(0.4), radius: 24, y: 8)   // §01 0 8 24 black@40%
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 36)).foregroundStyle(Theme.bg)   // dark-on-amber (§03D)
                }
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
            .accessibilityIdentifier("npPlayPause").accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

            Button { engine.next() } label: {
                Image(systemName: "forward.fill").font(.system(size: 34)).foregroundStyle(Theme.text)
            }.buttonStyle(.plain).frame(maxWidth: .infinity)

            Button { engine.setRepeat(!engine.isRepeat) } label: {
                Image(systemName: "repeat").font(.system(size: 22))
                    .foregroundStyle(engine.isRepeat ? Theme.accent : .white.opacity(0.85))
            }.buttonStyle(.plain).frame(maxWidth: .infinity)
        }
    }
```
Wire `transportRow` into the `VStack`.

- [ ] **Step 6: Build + screenshot + run queue tests.** Confirm the amber play/pause circle with a **dark** glyph, and shuffle/repeat tint accent when active. Commit:

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/PlaybackQueueTests 2>&1 | tail -8
git add apps/nano-ios/Sources/Playback/AudioEngine.swift apps/nano-ios/Sources/Playback/PlaybackQueue.swift \
  apps/nano-ios/Sources/Screens/NowPlayingScreen.swift apps/nano-ios/Tests/PlaybackQueueTests.swift
git commit -m "feat(ios): Now Playing transport row + reshuffle-in-place toggleShuffle"
```

- [ ] **Verify against the handoff:** `03-screens.md` §D item 8 (shuffle·prev 34·play-pause 76 amber·next 34·repeat; accent when active; glyph in `bg`) + Behavior (prev/next/shuffle/repeat drive the engine); `screens-now.jsx` transport.

---

## Task 6: Volume API on `AudioEngine` + Now Playing volume row

**Files:** Modify `Sources/Playback/AudioEngine.swift`, `Sources/Screens/NowPlayingScreen.swift`, `Tests/AudioEngineTests.swift`.

- [ ] **Step 1: Write the failing test** — append to `Tests/AudioEngineTests.swift`:

```swift
    @MainActor
    func test_setVolumeClampsToUnitRange() {
        let engine = AudioEngine()
        engine.setVolume(0.5);  XCTAssertEqual(engine.volume, 0.5, accuracy: 1e-6)
        engine.setVolume(1.7);  XCTAssertEqual(engine.volume, 1.0, accuracy: 1e-6)
        engine.setVolume(-0.3); XCTAssertEqual(engine.volume, 0.0, accuracy: 1e-6)
    }
```

- [ ] **Step 2: Run — expect FAIL** (`volume`/`setVolume` missing).

- [ ] **Step 3: Implement on `AudioEngine`** — add the observable property + setter (it sets the existing `player.volume`):

```swift
    private(set) var volume: Double = 1.0

    func setVolume(_ v: Double) {
        let clamped = min(1, max(0, v))
        volume = clamped
        player.volume = Float(clamped)
    }
```

- [ ] **Step 4: Run — expect PASS.**

- [ ] **Step 5: Add the volume row** to `NowPlayingScreen` (insert below `transportRow`):

```swift
    @ViewBuilder private var volumeRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "waveform").font(.system(size: 16)).foregroundStyle(.white.opacity(0.4))
            GeometryReader { geo in                                    // custom: track white@14%, fill white@85%, white knob
                let w = geo.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14)).frame(height: 4)
                    Capsule().fill(.white.opacity(0.85)).frame(width: w * engine.volume, height: 4)
                    Circle().fill(.white).frame(width: 14, height: 14)
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        .offset(x: max(0, min(w - 14, w * engine.volume - 7)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { engine.setVolume(min(1, max(0, $0.location.x / w))) })
            }
            .frame(height: 24).accessibilityIdentifier("npVolume")
            Image(systemName: "waveform").font(.system(size: 22)).foregroundStyle(.white.opacity(0.4))  // asymmetric 16/22 (§ JSX)
        }
    }
```
Wire `volumeRow` into the `VStack`.

- [ ] **Step 6: Build + screenshot + full suite. Commit:**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/AudioEngineTests 2>&1 | tail -8
git add apps/nano-ios/Sources/Playback/AudioEngine.swift apps/nano-ios/Sources/Screens/NowPlayingScreen.swift apps/nano-ios/Tests/AudioEngineTests.swift
git commit -m "feat(ios): AudioEngine player-gain volume + Now Playing volume row"
```

- [ ] **Verify against the handoff:** `03-screens.md` §D item 9 (wave · slider · wave; "player gain node" allowed); `screens-now.jsx` volume (fill white@85%, not accent).

---

## Task 7: Re-home `OverviewWaveform` scrubber + LUFS badge + time row; retire `TrackDetailScreen`

**Files:** Create `Sources/Components/LUFSBadge.swift`; Modify `Sources/Screens/NowPlayingScreen.swift`, `Sources/Screens/LibraryScreen.swift`, `Sources/Screens/PlaylistDetailScreen.swift`; **Delete** `Sources/Screens/TrackDetailScreen.swift`.

- [ ] **Step 1: Create `Sources/Components/LUFSBadge.swift`** (handoff §02 NMLufs capsule; Phase 4 value = integrated):

```swift
import SwiftUI

/// Glass-capsule LUFS badge that floats over the overview (handoff §02 NMLufs). Phase 4 shows the
/// per-track INTEGRATED value; Phase 5 swaps in the live short-term meter (same capsule/placement).
struct LUFSBadge: View {
    var lufs: Double?
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {        // §02 NMLufs badge: [S][value][LUFS]
            Text("S").font(Theme.mono(9.5, .semibold)).tracking(1.2).foregroundStyle(Theme.text3)
            Text(lufs.map { String(format: "%.1f", $0) } ?? "—")
                .font(Theme.mono(13, .semibold)).tracking(-0.2).monospacedDigit().foregroundStyle(Theme.text)
            Text("LUFS").font(Theme.mono(9, .semibold)).tracking(0.8).foregroundStyle(Theme.text3)
        }
        .padding(.vertical, 3).padding(.horizontal, 8)
        .background(Color(hex: 0x14161C).opacity(0.7), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(.white.opacity(0.12), lineWidth: 0.5))
    }
}
```

- [ ] **Step 2: Add the scrubber + time row** to `NowPlayingScreen` (between `titleRow` and `transportRow`). Add `@AppStorage` + bins state:

```swift
    @AppStorage("showWave") private var showWave = true
    @AppStorage("spectrum") private var spectrum = false
    @State private var bins: [WaveBin] = []
```
```swift
    @ViewBuilder private var scrubber: some View {
        if showWave {
            OverviewWaveform(bins: bins, progress: engine.progress, coloringOn: spectrum,
                             onScrub: { engine.seek(toFraction: $0) })
                .overlay(alignment: .topTrailing) {
                    LUFSBadge(lufs: engine.current?.integratedLUFS).offset(y: -6)
                }
        } else {                                   // both/overview off → plain 6pt bar (§03D item 5)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.16)).frame(height: 6)
                    Capsule().fill(Theme.accent).frame(width: geo.size.width * engine.progress, height: 6)
                    Circle().fill(.white).frame(width: 14, height: 14)              // §03D item 5: 14pt white knob
                        .shadow(color: .black.opacity(0.4), radius: 4, y: 1)
                        .offset(x: max(0, min(geo.size.width - 14, geo.size.width * engine.progress - 7)))
                }
                .frame(maxHeight: .infinity, alignment: .center)
                .contentShape(Rectangle())
                .gesture(DragGesture(minimumDistance: 0).onChanged { engine.seek(toFraction: min(1, max(0, $0.location.x / geo.size.width))) })
            }
            .frame(height: 14)
        }
    }

    @ViewBuilder private var timeRow: some View {
        let dur = engine.current?.durationSec ?? 0
        HStack {
            Text(PlaybackMath.clock(engine.elapsed))
            Spacer()
            if !showWave {                                   // no overview → LUFS sits inline here as plain text (NOT the capsule)
                Text((engine.current?.integratedLUFS).map { String(format: "%.1f LUFS", $0) } ?? "— LUFS")
                    .foregroundStyle(.white.opacity(0.55))
                Spacer()
            }
            Text("-" + PlaybackMath.clock(max(0, dur - engine.elapsed)))
        }
        .font(Theme.mono(12)).foregroundStyle(.white.opacity(0.5))
    }
```
Wire `scrubber` then `timeRow` into the `VStack` (above `transportRow`), and load bins:

```swift
        .task(id: engine.current?.persistentModelID) {
            if let t = engine.current { bins = await WaveformStore.shared.bins(for: t) ?? [] }
        }
```

- [ ] **Step 3: Retire `TrackDetailScreen`.** In `LibraryScreen.swift` and `PlaylistDetailScreen.swift`, replace the `.sheet(item: $detailTrack) { TrackDetailScreen(track: $0) }` with the context sheet, and keep the `onEllipsis: { detailTrack = … }` wiring:

```swift
        .sheet(item: $detailTrack) { TrackContextSheet(track: $0) }
```
> `TrackContextSheet` may still be the temporary stub from Task 4 (or its real form once Task 9 lands) — either compiles. Then **delete** `Sources/Screens/TrackDetailScreen.swift`.

- [ ] **Step 4: Build (no dangling `TrackDetailScreen` refs) + run the waveform UI test + screenshot Now Playing:**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild build -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' -derivedDataPath build 2>&1 | tail -3
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersUITests/WaveformUITests 2>&1 | tail -12
```
> `WaveformUITests` (Phase 3) opened the overview via the row ellipsis → `TrackDetailScreen`, which no longer exists. **Update that test** to open Now Playing instead (tap the track → tap `miniPlayerTitle` → assert `app.otherElements["overviewWaveform"]` inside `nowPlaying`, then scrub). Adjust it so it passes; report the change.

- [ ] **Step 5: Full suite — expect PASS. Commit:**

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | grep -E "Executed [0-9]+ test|\*\* TEST" | tail -4
git add -A apps/nano-ios
git commit -m "feat(ios): re-home overview scrubber + LUFS badge on Now Playing; retire TrackDetailScreen"
```

- [ ] **Verify against the handoff:** `03-screens.md` §D items 4–6 (overview 62pt draggable + floating LUFS badge top-right; both-off → plain 6pt bar; time row elapsed/-remaining, LUFS centered when no wave); `screens-now.jsx:311-332`. `OverviewWaveform.swift` doc ("re-host unchanged").

---

## Task 8: Settings sheet + `@AppStorage` single source of truth

**Files:** Create `Sources/Screens/SettingsSheet.swift`; Modify `Sources/Screens/LibraryScreen.swift`.

- [ ] **Step 1: Create `Sources/Screens/SettingsSheet.swift`:**

```swift
import SwiftUI

/// App settings (handoff §03 §6 / §02). The "Waveform Display" toggles are the SINGLE source of
/// truth for what Now Playing renders — there are no equivalent controls on the player. Persisted
/// app-wide via @AppStorage. Frequency coloring is disabled when both waveforms are off.
struct SettingsSheet: View {
    @AppStorage("zoomWave") private var zoomWave = false      // Close-up (Phase 5 surface; off in v1)
    @AppStorage("showWave") private var showWave = true       // Track overview
    @AppStorage("spectrum") private var spectrum = false      // Frequency coloring
    @Environment(\.dismiss) private var dismiss

    private var bothOff: Bool { !zoomWave && !showWave }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    settingsToggle("waveform.path", "Close-up (DJ scroll)", "Zoomed, scrolling waveform", $zoomWave)
                    settingsToggle("waveform", "Track overview", "Full-song scrubber", $showWave)
                    settingsToggle("paintpalette", "Frequency coloring", "Red bass · green mids · blue treble", $spectrum)
                        .disabled(bothOff).opacity(bothOff ? 0.4 : 1)
                } header: {
                    Text("Waveform Display")
                } footer: {
                    Text("Close-up is a zoomed, scrolling waveform that scrolls past a fixed playhead; Track overview is the full-song scrubber.")
                }
            }
            .tint(Theme.accent)
            .scrollContentBackground(.hidden).background(Theme.bg)
            .navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
        .preferredColorScheme(.dark)
    }

    /// SettingsRow (§02): [accent icon 20] [title 16/500 + sub 12.5/text3] [iOS switch].
    private func settingsToggle(_ icon: String, _ title: String, _ sub: String, _ isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 20)).foregroundStyle(Theme.accent).frame(width: 24)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(Theme.sans(16, .medium)).foregroundStyle(Theme.text)
                    Text(sub).font(Theme.sans(12.5)).foregroundStyle(Theme.text3)
                }
            }
        }
    }
}
```

- [ ] **Step 2: Wire the gear button** in `LibraryScreen.swift`. The header's `GlassRoundButton(systemName: "gearshape")` currently has no action — give it one + present the sheet. Add state `@State private var showSettings = false`, change the gear button to `GlassRoundButton(systemName: "gearshape") { showSettings = true }`, and add `.sheet(isPresented: $showSettings) { SettingsSheet() }`.

- [ ] **Step 3: Build + UI test** the gating — add to `NowPlayingUITests` (or a Settings UI test): open the gear → Settings; toggle "Track overview" off → present Now Playing → assert `overviewWaveform` is absent (plain bar shown). Keep it simple/deterministic.

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersUITests/NowPlayingUITests 2>&1 | tail -15
```

- [ ] **Step 4: Commit**

```sh
git add apps/nano-ios/Sources/Screens/SettingsSheet.swift apps/nano-ios/Sources/Screens/LibraryScreen.swift apps/nano-ios/UITests/NowPlayingUITests.swift
git commit -m "feat(ios): Settings sheet — waveform display @AppStorage (single source of truth)"
```

- [ ] **Verify against the handoff:** `03-screens.md` §6 (insetGrouped; 3 toggles; spectrum disabled when both off; single source of truth, no toggles on the player); `02-components.md` IOSSwitch (`Toggle.tint(accent)`); `tweaks-panel.jsx`.

---

## Task 9: Track context sheet + Add-to-Playlist + Up Next/Queue + bottom rail

**Files:** Create `Sources/Screens/TrackContextSheet.swift`, `Sources/Screens/AddToPlaylistSheet.swift`, `Sources/Screens/QueueSheet.swift`, `Sources/Components/AirPlayButton.swift`; Modify `Sources/Screens/NowPlayingScreen.swift`. (Remove the Task-4 `TrackContextSheet` stub.)

> Engine queue ops: `AudioEngine` has `jump(to:)` and a `queue: PlaybackQueue` (with `tracks`/`index`). "Play Next" / "Add to Queue" need small queue inserts — add `func playNext(_:)` and `func enqueue(_:)` to `AudioEngine` that mutate `queue.tracks` (insert after `index` / append) on the main actor. Add these in this task.

- [ ] **Step 1: Add queue inserts to `AudioEngine`** + a `PlaybackQueue` helper:

In `PlaybackQueue.swift`:
```swift
    mutating func insertNext(_ t: Track) { tracks.insert(t, at: min(index + 1, tracks.count)) }
    mutating func append(_ t: Track) { tracks.append(t) }
```
In `AudioEngine.swift`:
```swift
    func playNext(_ track: Track) { queue.insertNext(track) }
    func enqueue(_ track: Track)  { queue.append(track) }
```

- [ ] **Step 2: Create `AddToPlaylistSheet.swift`** (track→playlists membership):

```swift
import SwiftUI
import SwiftData

/// Toggle a single track's membership across playlists (the inverse of AddSongsSheet). §03 sheet 4.
struct AddToPlaylistSheet: View {
    @Environment(\.modelContext) private var ctx
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @Query(sort: \Playlist.dateCreated, order: .reverse) private var playlists: [Playlist]
    @State private var newPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Button { newPlaylist = true } label: {                 // §4 first row: New Playlist (dashed tile)
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .strokeBorder(Theme.text3, style: StrokeStyle(lineWidth: 1.5, dash: [5]))
                            .overlay(Image(systemName: "plus").foregroundStyle(Theme.accent))
                            .frame(width: 44, height: 44)
                        Text("New Playlist").font(Theme.sans(16.5, .semibold)).foregroundStyle(Theme.accent)
                        Spacer()
                    }
                }.listRowBackground(Theme.bg)

                ForEach(playlists) { pl in
                    let inList = pl.itemIDs.contains(track.id)
                    Button {
                        if inList { pl.itemIDs.removeAll { $0 == track.id } } else { LibraryStore.append(track, to: pl) }
                    } label: {
                        HStack {
                            PlaylistCover(artworks: (try? LibraryStore.tracks(in: pl, ctx))?.map(\.artworkData) ?? [], size: 44)
                            Text(pl.name).font(Theme.sans(16, .medium)).foregroundStyle(Theme.text)
                            Spacer()
                            Image(systemName: inList ? "checkmark" : "plus").foregroundStyle(Theme.accent)
                        }
                    }.listRowBackground(Theme.bg)
                }
            }
            .listStyle(.plain).background(Theme.bg)
            .navigationTitle("Add to Playlist").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $newPlaylist) { NewPlaylistSheet() }   // match the real Phase-1 NewPlaylistSheet init (seed with `track` if it takes one)
        }
        .preferredColorScheme(.dark)
    }
}
```

- [ ] **Step 3: Create `QueueSheet.swift`** (Up Next; tap → jump):

```swift
import SwiftUI

/// Up Next — the live queue (handoff §03 sheet 7): now-playing header + the upcoming list + an
/// "End of queue" empty state; title carries the current context name. Tapping a row jumps to it.
struct QueueSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    @State private var bins: [WaveBin] = []

    /// (absolute queue index, track) for everything AFTER the current index.
    private var upcoming: [(offset: Int, track: Track)] {
        let tracks = engine.queue.tracks, idx = engine.queue.index
        guard idx + 1 < tracks.count else { return [] }
        return tracks[(idx + 1)...].enumerated().map { (idx + 1 + $0.offset, $0.element) }
    }

    var body: some View {
        NavigationStack {
            List {
                if let cur = engine.current {                       // now-playing header block
                    HStack(spacing: 12) {
                        NMArtwork(data: cur.artworkData, size: 44, radius: 9)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(cur.title).font(Theme.sans(15.5, .semibold)).foregroundStyle(Theme.accent).lineLimit(1)
                            Text("Now Playing").font(Theme.sans(12.5)).foregroundStyle(Theme.text2)
                        }
                        Spacer()
                        if !bins.isEmpty { NMMiniWave(bins: bins, bars: 22).frame(width: 48, height: 20) }
                    }
                    .listRowBackground(Theme.bg)
                    Divider().background(Theme.hair).listRowBackground(Theme.bg)
                }
                if upcoming.isEmpty {
                    Text("End of queue").font(Theme.sans(14)).foregroundStyle(Theme.text3)
                        .frame(maxWidth: .infinity).padding(.vertical, 24).listRowBackground(Theme.bg)
                } else {
                    ForEach(upcoming, id: \.track.id) { item in
                        Button { engine.jump(to: item.offset); dismiss() } label: {
                            HStack(spacing: 12) {
                                NMArtwork(data: item.track.artworkData, size: 42, radius: 8)
                                VStack(alignment: .leading) {
                                    Text(item.track.title).font(Theme.sans(15, .medium)).foregroundStyle(Theme.text).lineLimit(1)
                                    Text(item.track.artist).font(Theme.sans(12.5)).foregroundStyle(Theme.text2).lineLimit(1)
                                }
                                Spacer()
                            }
                        }.listRowBackground(Theme.bg)
                    }
                }
            }
            .listStyle(.plain).background(Theme.bg)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text("Up Next").font(Theme.sans(17, .semibold)).foregroundStyle(Theme.text)
                        Text(engine.context.name).font(Theme.mono(12)).foregroundStyle(Theme.text3)
                    }
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task(id: engine.current?.persistentModelID) {
                if let c = engine.current { bins = await WaveformStore.shared.bins(for: c) ?? [] }
            }
        }
        .preferredColorScheme(.dark)
    }
}
```
> `engine.queue` is currently `var queue: PlaybackQueue` — confirm it's accessible (it is, non-private per Phase 2). If `private`, expose a read-only `var queueTracks: [Track]` + `var queueIndex: Int` on `AudioEngine` and use those instead.

- [ ] **Step 4: Create `TrackContextSheet.swift`** (local actions) and `AirPlayButton.swift`:

```swift
import SwiftUI

/// Track context menu (handoff §03 sheet 1) — local actions only. Source Folder / Remove Download
/// are v2 (cloud) and omitted.
struct TrackContextSheet: View {
    @Environment(AudioEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss
    let track: Track
    @State private var addToPlaylist = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 12) {
                        NMArtwork(data: track.artworkData, size: 52, radius: 8)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(track.title).font(Theme.sans(16, .semibold)).foregroundStyle(Theme.text)
                            Text(track.artist).font(Theme.sans(13)).foregroundStyle(Theme.text2)
                            Text("\(track.format) · \(track.sampleRate) kHz").font(Theme.mono(11)).foregroundStyle(Theme.text3)
                        }
                        Spacer()
                    }.listRowBackground(Theme.bg)
                }
                Section {
                    action("Play Next", "text.line.first.and.arrowtriangle.forward") { engine.playNext(track); dismiss() }
                    action("Add to Queue", "list.bullet.indent") { engine.enqueue(track); dismiss() }
                    action("Add to Playlist…", "plus.circle") { addToPlaylist = true }
                    action(track.isLoved ? "Loved" : "Love", track.isLoved ? "heart.fill" : "heart") { track.isLoved.toggle() }
                }.listRowBackground(Theme.bg)
            }
            .listStyle(.plain).background(Theme.bg)
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(isPresented: $addToPlaylist) { AddToPlaylistSheet(track: track) }
        }
        .preferredColorScheme(.dark)
    }

    private func action(_ title: String, _ icon: String, _ run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Label(title, systemImage: icon).foregroundStyle(Theme.text)
        }
    }
}
```
```swift
import SwiftUI
import AVKit

/// AirPlay route picker for the Now Playing bottom rail (handoff §03D item 10).
struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.activeTintColor = UIColor(Theme.accent)
        v.tintColor = UIColor(Theme.text2)
        return v
    }
    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}
```

- [ ] **Step 5: Add the bottom rail** to `NowPlayingScreen` (below `volumeRow`) + present the queue. Add `@State private var showQueue = false`:

```swift
    @ViewBuilder private var bottomRail: some View {
        HStack {
            Image(systemName: "folder").font(.system(size: 20)).foregroundStyle(Theme.text3)
                .frame(maxWidth: .infinity).opacity(0.4)        // Go-to-Source-Folder is v2
            AirPlayButton().frame(width: 44, height: 44).frame(maxWidth: .infinity)
            Button { showQueue = true } label: {
                Image(systemName: "list.bullet.indent").font(.system(size: 20)).foregroundStyle(Theme.text2)
            }.buttonStyle(.plain).frame(maxWidth: .infinity).accessibilityIdentifier("npQueue")
        }
    }
```
Wire `bottomRail` into the `VStack` and add `.sheet(isPresented: $showQueue) { QueueSheet() }`. Remove the temporary `TrackContextSheet` stub added in Task 4.

- [ ] **Step 6: Build + full suite + UI test the context/queue:**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | grep -E "Executed [0-9]+ test|\*\* TEST" | tail -4
```
(Optionally add a UI assertion: row ellipsis → context sheet shows "Play Next"; NP queue button → "Up Next".)

- [ ] **Step 7: Commit**

```sh
git add -A apps/nano-ios
git commit -m "feat(ios): track context / add-to-playlist / queue sheets + Now Playing bottom rail"
```

- [ ] **Verify against the handoff:** `03-screens.md` sheets 1/4/7 (context menu local actions; add-to-playlist; Up Next) + §D item 10 (folder · airplay · queue); deferred Source Folder/Remove Download omitted; `NewPlaylistSheet` pattern (NavigationStack + toolbar, no autofocus).

---

## Task 10: Reduce Motion + final polish & review pass

**Files:** Modify `Sources/Screens/NowPlayingScreen.swift`, `Sources/RootView.swift`.

- [ ] **Step 1: Honor Reduce Motion.** In `NowPlayingScreen`, add `@Environment(\.accessibilityReduceMotion) private var reduceMotion` and gate the paused-scale flourish:

```swift
                .scaleEffect(reduceMotion ? 1.0 : (engine.isPlaying ? 1.0 : 0.86))
```
(Keep present/dismiss; only drop the scale jump.) If desired, also drop the spring's bounce when reduceMotion (use `.easeInOut` in `open()`/`close()` — optional).

- [ ] **Step 2: Full clean run on iOS 26.5:**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | grep -E "Executed [0-9]+ test|\*\* TEST" | tail -6
```
Expected: all unit + UI suites pass (Theme, ArtworkTintStore, PlaybackQueue, AudioEngine, NowPlayingUITests, WaveformUITests, PlaybackUITests, …).

- [ ] **Step 3: Manual walkthrough** (install + launch): tap a track → tap mini player → Now Playing morphs up, tab bar hides; play/pause (dark glyph on amber), next/prev, shuffle/repeat tint; drag the overview to scrub + the LUFS badge; volume slider; heart persists; ellipsis → context sheet (Play Next / Add to Queue / Add to Playlist / Love); queue button → Up Next; gear → Settings, toggle Track overview off → NP shows the plain bar; chevron + swipe-down dismiss. Toggle Reduce Motion → present is a fade, no scale jump.

- [ ] **Step 4: Verify the whole phase against the handoff** (§03D top→bottom + behaviors; §02 buttons/IOSSwitch; §01 motion). Note drift; fix or flag.

- [ ] **Step 5: Confirm clean tree + chain. Commit:**

```sh
git add apps/nano-ios/Sources/Screens/NowPlayingScreen.swift apps/nano-ios/Sources/RootView.swift
git commit -m "polish(ios): Reduce Motion degrade + Now Playing final pass"
git -C /Users/wasp/Developer/nanometers/.claude/worktrees/nano-ios log --oneline main..HEAD
```

- [ ] **Verify against the handoff:** `01-design-tokens.md` motion footer (keep crossfade under Reduce Motion, drop scale); whole §D.

---

## Self-Review (run before execution)

**Spec coverage** (Phase 4 = "Now Playing + transition: full screen, matchedGeometryEffect, artwork-tint gradient, transport / volume / bottom rail, Settings sheet (@AppStorage), all sheets except cloud ones"):
- Full screen + matchedGeometryEffect + transition → Tasks 2 (overlay/namespace), 10 (Reduce Motion). ✓
- Artwork-tint gradient → Task 3. ✓
- Transport → Task 5; volume → Task 6; bottom rail → Task 9. ✓
- Overview scrubber re-home + LUFS badge + time row → Task 7. ✓
- Settings sheet + @AppStorage → Task 8. ✓
- Sheets except cloud → Task 9 (context/add-to-playlist/queue; Sources/Source-Folder deferred). ✓
- Top bar + title + heart → Task 4. ✓

**Placeholder scan:** the only intentional temporary is the Task-4 `TrackContextSheet` stub, explicitly removed in Task 9; the bottom-rail `folder` is a deliberately-disabled v2 stub.

**Type consistency:** `NowPlayingScreen(namespace:onClose:)` matches RootView's call; `matchedGeometryEffect(id: "artwork-\(track.id)")` is identical in MiniPlayer + the hero; `engine.toggleShuffle`/`setRepeat`/`setVolume`/`volume`/`playNext`/`enqueue`/`jump(to:)`/`queue` are all defined before use; `@AppStorage` keys `showWave`/`spectrum`/`zoomWave` are spelled identically in `NowPlayingScreen` + `SettingsSheet`; `OverviewWaveform(bins:progress:coloringOn:onScrub:)` matches its Phase-3 signature; `NMLufsValue(lufs:)` reused by `LUFSBadge`.

**Gotchas honored:** in-tree overlay not cover (Task 2); MiniPlayer stays mounted (gated on `current`, not `!npOpen`); tint fallback for art-less demo tracks (Task 3); `toggleShuffle` reshuffles (Task 5); player-gain volume (Task 6); `TrackDetailScreen` deleted only after re-home (Task 7) + `WaveformUITests` updated; 26pt side padding; dark-on-amber play glyph; chevron-primary XCUITest dismiss (Task 2); Add-to-Playlist is a new inverse component (Task 9).
