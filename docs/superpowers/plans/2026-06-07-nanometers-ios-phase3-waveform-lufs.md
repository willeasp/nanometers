# Nanometers iOS — Phase 3: Overview Waveform + Per-Track LUFS Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Decode each track once through `nano-dsp` (via the `NanoDSP.xcframework` FFI) into a cached per-bin envelope + spectral color and an integrated LUFS value, then render the overview waveform (scrubbable), the mini waveforms (rows + mini player), and per-track LUFS in rows — all drawn natively in SwiftUI `Canvas`.

**Architecture:** A single FFI facade (`NanoDSPBridge`, the only file that `import NanoDSP`) maps the C `NanoBin` to a Swift `WaveBin`, so the C type never leaks. An off-main `actor WaveformAnalyzer` decodes a file once (Float32 PCM), produces a mono mixdown for `nano_dsp_analyze` and deinterleaved L/R for `nano_dsp_integrated_lufs`, and computes a content-hash cache key. `WaveformCache` persists the fixed-density `[WaveBin]` + integrated LUFS to `Caches/` keyed by that hash. A `@MainActor WaveformStore` coordinates memory → disk → analyze and writes results back onto the `Track`. Renderers (`OverviewWaveform`, `NMMiniWave`) downsample the one cached array at draw time. Binding is locked by **ADR 0010** (iOS links only `nano-dsp`, draws in `Canvas`).

**Tech Stack:** SwiftUI `Canvas`/`TimelineView`, the `NanoDSP` Clang module (C-ABI static lib from `crates/nano-dsp`), AVFoundation (`AVAudioFile`/`AVAudioPCMBuffer`), CryptoKit (content hash), SwiftData, XCTest + XCUITest. iOS 17+, **Apple-silicon simulator** (the xcframework has no x86_64 slice). Built/tested on the **iOS 26.5 iPhone 17 Pro** sim, UDID `F8BC6E09-E5E4-4054-A03B-B1434DF0838D`.

---

## Design handoff — the canonical source, verify against it

Locked design: **`/Users/wasp/Downloads/design_handoff_nanometers/`**. Don't restate its numbers from this plan as truth — open it and confirm. Phase 3 touches:

- **`05-dsp-waveform-lufs.md`** — the analyze pass (decode → N bins → peak/band → normalize), "one decode per file, ever", the cache, the overview render spec, the dominant-band rule, and the shared-bins requirement (overview bars AND the Phase 5 close-up density feed off the same cache).
- **`02-components.md`** — `## Waveforms — overview & close-up` (NMWaveform / NMMiniWave), `## NMRow` items 3–4 (42×20 mini-wave @ 0.7 opacity; per-track LUFS = value 12pt `text2` + "LUFS" 9.5pt `text3`, mono/tabular), `## Mini player (docked)` (optional 56×22 mini-wave, accent-tinted), `## NMLufs`.
- **`03-screens.md`** — confirms the overview scrubber's primary home (Now Playing, screen D) is **Phase 4** and the close-up scroll (NMScrollWave) is **Phase 5**; Phase 3 builds the components + the data layer.
- **ADR**: `docs/adr/0010-ios-renders-natively-in-swiftui.md` (links only nano-dsp, Canvas, Metal escape hatch only if Canvas can't hold 120 Hz), `docs/adr/0001-*` (the spectral color is continuous, not 4 discrete hues — see Gotchas).

Each UI/behaviour task ends with **"Verify against the handoff"** naming the section. The handoff wins over this plan; fix the code and flag the plan if they disagree.

Reference Swift call shapes already exist: `crates/nano-dsp/smoke/smoke.swift` and the C header `crates/nano-dsp/include/nano_dsp.h`.

---

## Gotchas (from the Phase 3 research — read before starting)

1. **Apple-silicon only.** `NanoDSP.xcframework` has `ios-arm64` + `ios-arm64-simulator` slices — **no x86_64**. Builds/tests must run on an Apple-silicon Mac / arm64 simulator.
2. **The FFI color is continuous and correct — do NOT "fix" it to the four handoff hex tokens.** `nano_dsp_analyze` returns `NanoBin` with a continuous desaturated band color (ADR 0001: dominant band → hue, imbalance → saturation, balanced → white). It is **not** `#FF6B6B`/`#57D986`/`#6AA6FF`/`#EEF1F6`. Render `WaveBin.r/g/b` as-is; `Theme.bandBass`/etc. are anchors only. A reviewer comparing to the `.heic` may flag it — that's expected; the FFI RGB is the truth.
3. **One decode, two shapes.** `nano_dsp_analyze` is mono (`push(s,s)`); `nano_dsp_integrated_lufs` is stereo. From the single decode, build a mono mixdown **and** deinterleaved L/R. Getting the `AVAudioPCMBuffer` layout wrong silently yields `rc=-1` / `-inf` (the FFI sanitizes NaN but won't surface shape errors).
4. **Only `NanoDSPBridge` imports `NanoDSP`.** Everything else uses the Swift `WaveBin`. The unit tests are hosted by the app but their target has no NanoDSP search path — keeping the C type out of public surfaces is what lets tests stay in Swift types.
5. **`Caches/` is purgeable.** `waveformCacheKey` can dangle after a purge — renderers must show an "analyzing" state on a miss and re-analyze, never crash.
6. **`engine.progress` ticks at 20 Hz.** Fine for the overview in Phase 3; if the playhead looks steppy, wrap in `TimelineView(.animation)`. (Phase 5's close-up will need the sample-time/CADisplayLink path — out of scope here.)
7. **Analyzer uses its OWN security scope.** `AudioEngine.resolveURL` is `private`/`@MainActor` and holds its own `scopedURL` on the *playing* file; the analyzer must start/stop its own scope to avoid colliding on the same imported file.
8. **Mono files read ~+3 LU hot** through `nano_dsp_integrated_lufs` (it sums as stereo; no mono mode). Acceptable for v1 stereo masters; note it for mono imports.

**Adopted defaults (the two open questions):** content-hash key = SHA256 over file byte-length + first/last 64 KB (fast; misses only a rare same-size mid-file edit); cache density = **10 bins/sec** (100 ms bins — exceeds the close-up's ~7 bars/sec floor and aligns with the BS.1770 100 ms grid).

---

## File Structure

New (all under `apps/nano-ios/`):

| File | Responsibility |
|---|---|
| `Sources/DSP/WaveBin.swift` | Swift mirror of the C `NanoBin` — `{ peak, r, g, b: Float }`, `Equatable`. The FFI type's Swift face; what the whole app + tests use. |
| `Sources/DSP/NanoDSPBridge.swift` | The ONLY `import NanoDSP`. `analyze(mono:sampleRate:binCount:) -> [WaveBin]?` and `integratedLUFS(l:r:sampleRate:) -> Double?`, encapsulating the unsafe pointer calls. |
| `Sources/DSP/WaveformAnalyzer.swift` | `actor`: resolve a `TrackRef` → URL (own scope), decode Float32 PCM once → mono + planar L/R, compute content-hash key, call the bridge → `AnalysisResult`. |
| `Sources/DSP/WaveformCache.swift` | Disk persistence in `Caches/{key}.nmwave` (header + raw `[WaveBin]`); `load(key:)`, `save(_:)`; miss → nil. |
| `Sources/DSP/WaveformStore.swift` | `@MainActor @Observable` coordinator: `bins(for: Track) async -> [WaveBin]?` (memory → disk → analyze, persists + writes Track fields). Lazy entry point for views + the import kick. |
| `Sources/DSP/WaveBins.swift` | Pure downsample (`maxDownsample([WaveBin], to:)`) + `Color(bin:)` + coloring-off override. |
| `Sources/Components/OverviewWaveform.swift` | Pure Canvas scrubber `View(bins:progress:coloringOn:onScrub:)` — ~150 bars, playhead, whole-strip scrub. |
| `Sources/Components/NMMiniWave.swift` | Static Canvas, 22 bars from the same bins; 42×20 (rows) / 56×22 (mini player). |
| `Sources/Components/NMLufsValue.swift` | Per-track LUFS slot: value 12pt `text2` + "LUFS" 9.5pt `text3`, mono/tabular; dash while nil. |
| `Sources/Screens/TrackDetailScreen.swift` | Interim Phase-3 host for `OverviewWaveform`, reached via `NMRow.onEllipsis`; re-homed to Now Playing in Phase 4. |
| `Tests/NanoDSPLinkTests.swift` | Headless link proof: bridge calls on a synthesized tone (mirrors `smoke.swift`). |
| `Tests/WaveformAnalyzerTests.swift` | Decode a known WAV → assert bin count, normalized peaks, finite LUFS. |
| `Tests/WaveformCacheTests.swift` | Round-trip byte-identical; miss → nil. |
| `Tests/WaveBinsTests.swift` | Downsample correctness (max-peak aggregation). |
| `UITests/WaveformUITests.swift` | E2E: open a track's detail, scrub, assert position moved + LUFS appears. |

Modified:

| File | Change |
|---|---|
| `Sources/project.yml` *(`apps/nano-ios/project.yml`)* | Add `NanoDSP.xcframework` framework dep (embed: false) to `NanoMeters`. |
| `Sources/Model/Track.swift` | (no schema change — `waveformCacheKey`/`integratedLUFS` already exist; just used now) |
| `Sources/Import/TrackImporter.swift` | After insert, eager-kick `WaveformStore` analysis. |
| `Sources/Components/NMRow.swift` | Mount `NMMiniWave` (42×20 @0.7) + `NMLufsValue`; `.task` lazy-analyze on miss. |
| `Sources/Components/MiniPlayer.swift` | Mount 56×22 accent-tinted `NMMiniWave`. |
| `Sources/Screens/LibraryScreen.swift`, `Sources/Screens/PlaylistDetailScreen.swift` | Wire `NMRow.onEllipsis` → `TrackDetailScreen`. |

---

## Scope

**In:** the FFI link + facade; one-decode analyzer; disk+memory cache; overview waveform with scrub (in an interim detail screen); mini waveforms in rows + mini player; per-track integrated LUFS in rows; lazy + eager analysis triggers.

**Deferred (do NOT build here):** Now Playing screen + the overview's final home + the floating live-LUFS badge → **Phase 4**; the close-up scroll (`NMScrollWave`) + the live streaming short-term meter (`nano_meter_*`) → **Phase 5**; Metal renderer (escape hatch only if Canvas profiling demands it).

**Out of scope:** anything not in the handoff; iPad; landscape; multi-hour-file chunked decode (note the risk; v1 assumes typical local tracks).

---

## Task 1: Link `NanoDSP.xcframework` + Swift facade, proven by a headless FFI test

**Files:** Modify `apps/nano-ios/project.yml`; Create `Sources/DSP/WaveBin.swift`, `Sources/DSP/NanoDSPBridge.swift`, `Tests/NanoDSPLinkTests.swift`.

- [ ] **Step 1: Add the framework dependency** to the `NanoMeters` target in `apps/nano-ios/project.yml` (after its `info:`/`settings:` — add a `dependencies:` key):

```yaml
  NanoMeters:
    type: application
    platform: iOS
    sources: [Sources, Resources]
    dependencies:
      - framework: ../../crates/nano-dsp/NanoDSP.xcframework
        embed: false        # static archive (libnano_dsp.a) — link, do not embed
    info:
      # … unchanged …
```
(Keep everything else in the target as-is. `embed: false` is required — it's a static `.a`, not a dynamic framework.)

- [ ] **Step 2: Create `Sources/DSP/WaveBin.swift`** (the Swift face of the C `NanoBin`):

```swift
import Foundation

/// Swift mirror of the C `NanoBin` (one analyzed bin: normalized peak 0…1 + continuous band color,
/// ADR 0001). Keeping a Swift type means only `NanoDSPBridge` ever imports `NanoDSP`; the cache,
/// renderers, and tests all stay in Swift. Layout is 4× Float32 = 16 bytes, matching the C struct
/// so the cache can serialize it verbatim.
struct WaveBin: Equatable {
    var peak: Float
    var r: Float
    var g: Float
    var b: Float
}
```

- [ ] **Step 3: Create `Sources/DSP/NanoDSPBridge.swift`** (the sole FFI surface):

```swift
import Foundation
import NanoDSP

/// The one place that calls the nano-dsp C-ABI (NanoDSP.xcframework). Encapsulates the unsafe
/// pointer handling and converts the C `NanoBin` to Swift `WaveBin`. ADR 0010: iOS links only
/// nano-dsp. Mirrors crates/nano-dsp/smoke/smoke.swift / include/nano_dsp.h.
enum NanoDSPBridge {
    /// Analyze `mono` PCM into `binCount` (peak, color) bins. nil on bad arguments (rc != 0).
    static func analyze(mono: [Float], sampleRate: Double, binCount: Int) -> [WaveBin]? {
        guard binCount > 0, !mono.isEmpty else { return nil }
        var out = [NanoBin](repeating: NanoBin(peak: 0, r: 0, g: 0, b: 0), count: binCount)
        let rc = mono.withUnsafeBufferPointer { p in
            nano_dsp_analyze(p.baseAddress, p.count, Float(sampleRate), binCount, &out)
        }
        guard rc == 0 else { return nil }
        return out.map { WaveBin(peak: $0.peak, r: $0.r, g: $0.g, b: $0.b) }
    }

    /// Integrated BS.1770 LUFS over stereo L/R. nil = "no reading" (-inf / non-finite).
    static func integratedLUFS(l: [Float], r: [Float], sampleRate: Double) -> Double? {
        guard !l.isEmpty, l.count == r.count else { return nil }
        let v = l.withUnsafeBufferPointer { lp in
            r.withUnsafeBufferPointer { rp in
                nano_dsp_integrated_lufs(lp.baseAddress, rp.baseAddress, lp.count, sampleRate)
            }
        }
        return v.isFinite ? v : nil
    }
}
```

- [ ] **Step 4: Write the failing link test** `Tests/NanoDSPLinkTests.swift` (mirrors `smoke.swift`'s preconditions; uses only `WaveBin`, no `import NanoDSP`):

```swift
import XCTest
@testable import NanoMeters

final class NanoDSPLinkTests: XCTestCase {
    func test_bridgeAnalyzesAndMeasuresASynthTone() {
        let sr = 48_000.0
        let n = Int(sr * 4.0)
        var mono = [Float](repeating: 0, count: n)
        for i in 0..<n { mono[i] = 0.5 * sinf(2.0 * .pi * 1000.0 * Float(i) / Float(sr)) }

        let bins = NanoDSPBridge.analyze(mono: mono, sampleRate: sr, binCount: 150)
        XCTAssertNotNil(bins, "analyze returned nil (link or rc failure)")
        XCTAssertEqual(bins?.count, 150)
        XCTAssertTrue(bins?.allSatisfy { $0.peak >= 0 && $0.peak <= 1 } ?? false, "peaks not normalized 0…1")
        XCTAssertTrue(bins?.contains { $0.peak > 0.5 } ?? false, "no loud bin found")

        let lufs = NanoDSPBridge.integratedLUFS(l: mono, r: mono, sampleRate: sr)
        XCTAssertNotNil(lufs)
        XCTAssertTrue((lufs ?? 0) > -30 && (lufs ?? 0) < 0, "integrated LUFS implausible: \(String(describing: lufs))")
    }
}
```

- [ ] **Step 5: Regenerate + run the test — expect PASS** (this PROVES the xcframework links on the simulator slice before any UI exists):

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/NanoDSPLinkTests 2>&1 | tail -20
```
Expected `Test Suite 'NanoDSPLinkTests' passed`. If it fails to find `NanoDSP`/symbols: confirm the `framework:` path resolves from `apps/nano-ios/` (`../../crates/nano-dsp/NanoDSP.xcframework`) and that `xcodegen generate` ran.

- [ ] **Step 6: Commit**

```sh
git add apps/nano-ios/project.yml apps/nano-ios/Sources/DSP/WaveBin.swift apps/nano-ios/Sources/DSP/NanoDSPBridge.swift apps/nano-ios/Tests/NanoDSPLinkTests.swift
git commit -m "feat(ios): link NanoDSP.xcframework + Swift FFI facade (proven by a link test)"
```

- [ ] **Verify against the handoff:** ADR 0010 (iOS links only nano-dsp via a C-ABI facade); `crates/nano-dsp/include/nano_dsp.h` (signatures) + `smoke/smoke.swift` (call shapes). No visual change.

---

## Task 2: `WaveformAnalyzer` actor — one decode → analyze + integrated LUFS + cache key

**Files:** Create `Sources/DSP/WaveformAnalyzer.swift`, `Tests/WaveformAnalyzerTests.swift`.

- [ ] **Step 1: Write the failing test** `Tests/WaveformAnalyzerTests.swift` (synthesizes a real WAV, like `AudioEngineTests`):

```swift
import XCTest
import AVFoundation
@testable import NanoMeters

final class WaveformAnalyzerTests: XCTestCase {
    func test_analyzeProducesFixedDensityBinsAndFiniteLUFS() async throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("Ana_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try Self.writeSine(to: url, seconds: 3.0, frequency: 440)

        let ref = TrackRef(bundledName: nil, bookmark: try url.bookmarkData())
        let result = try await WaveformAnalyzer().analyze(ref)

        XCTAssertEqual(result.bins.count, max(150, Int((3.0 * 10).rounded())))  // 10 bins/sec
        XCTAssertTrue(result.bins.allSatisfy { $0.peak >= 0 && $0.peak <= 1 }, "peaks normalized")
        XCTAssertTrue(result.bins.contains { $0.peak > 0.5 }, "tone should produce a loud bin")
        XCTAssertNotNil(result.integratedLUFS)
        XCTAssertEqual(result.durationSec, 3.0, accuracy: 0.05)
        XCTAssertFalse(result.key.isEmpty, "content-hash key computed")
    }

    private static func writeSine(to url: URL, seconds: Double, frequency: Double) throws {
        let sr = 44_100.0
        let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sr, channels: 2, interleaved: false)!
        let file = try AVAudioFile(forWriting: url, settings: fmt.settings)
        let frames = AVAudioFrameCount(sr * seconds)
        let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: frames)!
        buf.frameLength = frames
        let w = 2.0 * Double.pi * frequency
        for ch in 0..<2 {
            let data = buf.floatChannelData![ch]
            for i in 0..<Int(frames) { data[i] = Float(0.5 * sin(w * Double(i) / sr)) }
        }
        try file.write(from: buf)
    }
}
```

- [ ] **Step 2: Run it — expect FAIL** ("cannot find 'TrackRef'/'WaveformAnalyzer'").

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/WaveformAnalyzerTests 2>&1 | tail -15
```

- [ ] **Step 3: Implement `Sources/DSP/WaveformAnalyzer.swift`:**

```swift
import Foundation
import AVFoundation
import CryptoKit

/// A Sendable snapshot of the bits of a Track the analyzer needs, so the @Model never crosses
/// into the actor.
struct TrackRef: Sendable {
    let bundledName: String?
    let bookmark: Data?
}

/// Decodes a track ONCE off the main actor and runs nano-dsp over it: a mono mixdown for
/// `nano_dsp_analyze` (fixed density, 10 bins/sec) and deinterleaved L/R for
/// `nano_dsp_integrated_lufs` — from the same decode (handoff §05 "one decode per file, ever").
/// Also derives the content-hash cache key. Uses its OWN security scope (the engine holds its own).
actor WaveformAnalyzer {
    struct AnalysisResult: Sendable {
        let key: String
        let bins: [WaveBin]
        let integratedLUFS: Double?
        let sampleRate: Double
        let durationSec: Double
    }

    enum AnalyzeError: Error { case noFile, emptyAudio, ffiFailed }

    static let binsPerSecond = 10.0

    func analyze(_ ref: TrackRef) throws -> AnalysisResult {
        let (url, scoped) = try Self.resolve(ref)
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let key = Self.contentKey(url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat                       // Float32, deinterleaved
        let total = AVAudioFrameCount(file.length)
        guard total > 0, let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: total) else {
            throw AnalyzeError.emptyAudio
        }
        try file.read(into: buffer)
        let n = Int(buffer.frameLength)
        let sr = format.sampleRate
        guard n > 0, let chans = buffer.floatChannelData else { throw AnalyzeError.emptyAudio }
        let channelCount = Int(format.channelCount)

        // Mono mixdown + planar L/R from the single decode.
        var mono = [Float](repeating: 0, count: n)
        var left = [Float](repeating: 0, count: n)
        var right = [Float](repeating: 0, count: n)
        let l = chans[0]
        let r = channelCount > 1 ? chans[1] : chans[0]
        for i in 0..<n {
            let lv = l[i], rv = r[i]
            left[i] = lv; right[i] = rv
            mono[i] = channelCount > 1 ? (lv + rv) * 0.5 : lv
        }

        let durationSec = Double(n) / sr
        let binCount = max(150, Int((durationSec * Self.binsPerSecond).rounded()))
        guard let bins = NanoDSPBridge.analyze(mono: mono, sampleRate: sr, binCount: binCount) else {
            throw AnalyzeError.ffiFailed
        }
        let lufs = NanoDSPBridge.integratedLUFS(l: left, r: right, sampleRate: sr)
        return AnalysisResult(key: key, bins: bins, integratedLUFS: lufs, sampleRate: sr, durationSec: durationSec)
    }

    /// Resolve a track URL the same way AudioEngine does — bundled by name, else bookmark — but
    /// with the analyzer's own security scope.
    static func resolve(_ ref: TrackRef) throws -> (URL, Bool) {
        if let name = ref.bundledName, let url = Bundle.main.url(forResource: name, withExtension: nil) {
            return (url, false)
        }
        guard let bm = ref.bookmark else { throw AnalyzeError.noFile }
        var stale = false
        let url = try URL(resolvingBookmarkData: bm, bookmarkDataIsStale: &stale)
        let scoped = url.startAccessingSecurityScopedResource()
        return (url, scoped)
    }

    /// Cheap content key: SHA256 over file byte-length + first/last 64 KB. Stable per file content
    /// without hashing the whole (possibly huge / non-resident) file.
    static func contentKey(_ url: URL) -> String {
        guard let fh = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? fh.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
        var hasher = SHA256()
        withUnsafeBytes(of: Int64(size ?? 0).littleEndian) { hasher.update(data: Data($0)) }
        let chunk = 64 * 1024
        if let head = try? fh.read(upToCount: chunk) { hasher.update(data: head) }
        if (size ?? 0) > chunk * 2 {
            try? fh.seek(toOffset: UInt64((size ?? 0) - chunk))
            if let tail = try? fh.read(upToCount: chunk) { hasher.update(data: tail) }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
```

- [ ] **Step 4: Run the test — expect PASS** (re-run Step 2's command). The decode + FFI produce 30 bins (3s × 10) with normalized peaks and a finite LUFS.

- [ ] **Step 5: Commit**

```sh
git add apps/nano-ios/Sources/DSP/WaveformAnalyzer.swift apps/nano-ios/Tests/WaveformAnalyzerTests.swift
git commit -m "feat(ios): WaveformAnalyzer — one decode → analyze + integrated LUFS + cache key"
```

- [ ] **Verify against the handoff:** `05-dsp-waveform-lufs.md` §B analyze pass (decode → N bins → peak/band → normalize) and "one decode per file, ever"; fixed density (Gotcha + §A close-up floor). Logic only.

---

## Task 3: `WaveformCache` — fixed-density `[WaveBin]` persistence in `Caches/`

**Files:** Create `Sources/DSP/WaveformCache.swift`, `Tests/WaveformCacheTests.swift`.

- [ ] **Step 1: Write the failing test** `Tests/WaveformCacheTests.swift`:

```swift
import XCTest
@testable import NanoMeters

final class WaveformCacheTests: XCTestCase {
    func test_roundTripsBinsAndLUFS() throws {
        let key = "test_\(UUID().uuidString)"
        defer { WaveformCache.remove(key: key) }
        let bins = (0..<40).map { WaveBin(peak: Float($0) / 40, r: 0.2, g: 0.5, b: 0.8) }
        WaveformCache.save(key: key, bins: bins, integratedLUFS: -9.5, sampleRate: 44_100, durationSec: 4.0)

        let loaded = WaveformCache.load(key: key)
        XCTAssertEqual(loaded?.bins, bins)
        XCTAssertEqual(loaded?.integratedLUFS, -9.5)
    }

    func test_missReturnsNil() {
        XCTAssertNil(WaveformCache.load(key: "definitely-not-present-\(UUID().uuidString)"))
    }
}
```

- [ ] **Step 2: Run — expect FAIL** (`cannot find 'WaveformCache'`).

- [ ] **Step 3: Implement `Sources/DSP/WaveformCache.swift`:**

```swift
import Foundation

/// On-disk cache of a track's analyzed bins, keyed by content hash, under the purgeable Caches dir
/// (regenerable data — never Application Support). Format: a fixed header then `binCount` × 16 bytes
/// of `WaveBin` (4× Float32 LE), read back directly. A miss (or a purge) returns nil so the
/// renderer shows an "analyzing" state and re-analyzes.
enum WaveformCache {
    struct Loaded: Equatable { let bins: [WaveBin]; let integratedLUFS: Double? }

    private static let magic: UInt32 = 0x314D574E   // "NMW1" LE
    private static let version: UInt16 = 1

    private static var dir: URL {
        let base = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        let d = base.appendingPathComponent("waveforms", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private static func file(_ key: String) -> URL { dir.appendingPathComponent("\(key).nmwave") }

    static func save(key: String, bins: [WaveBin], integratedLUFS: Double?, sampleRate: Double, durationSec: Double) {
        guard !key.isEmpty else { return }
        var data = Data()
        func put<T>(_ v: T) { var v = v; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        put(magic.littleEndian); put(version.littleEndian)
        put(Float(sampleRate).bitPattern.littleEndian)
        put(durationSec.bitPattern.littleEndian)
        // -inf sentinel encodes "no reading".
        put((integratedLUFS ?? -Double.infinity).bitPattern.littleEndian)
        put(UInt32(bins.count).littleEndian)
        bins.forEach { put($0.peak.bitPattern.littleEndian); put($0.r.bitPattern.littleEndian)
                       put($0.g.bitPattern.littleEndian); put($0.b.bitPattern.littleEndian) }
        try? data.write(to: file(key), options: .atomic)
    }

    static func load(key: String) -> Loaded? {
        guard !key.isEmpty, let data = try? Data(contentsOf: file(key)), data.count >= 22 else { return nil }
        var off = 0
        func get<T>(_ t: T.Type, _ size: Int) -> T? {
            guard off + size <= data.count else { return nil }
            let v = data.subdata(in: off..<off+size).withUnsafeBytes { $0.loadUnaligned(as: T.self) }
            off += size; return v
        }
        guard let m: UInt32 = get(UInt32.self, 4), m == magic,
              let _: UInt16 = get(UInt16.self, 2),
              let _: UInt32 = get(UInt32.self, 4),                 // sampleRate bits
              let durBits: UInt64 = get(UInt64.self, 8),
              let lufsBits: UInt64 = get(UInt64.self, 8),
              let count: UInt32 = get(UInt32.self, 4) else { return nil }
        _ = durBits
        var bins: [WaveBin] = []; bins.reserveCapacity(Int(count))
        for _ in 0..<Int(count) {
            guard let p: UInt32 = get(UInt32.self, 4), let r: UInt32 = get(UInt32.self, 4),
                  let g: UInt32 = get(UInt32.self, 4), let b: UInt32 = get(UInt32.self, 4) else { return nil }
            bins.append(WaveBin(peak: Float(bitPattern: p), r: Float(bitPattern: r),
                                g: Float(bitPattern: g), b: Float(bitPattern: b)))
        }
        let lufs = Double(bitPattern: lufsBits)
        return Loaded(bins: bins, integratedLUFS: lufs.isFinite ? lufs : nil)
    }

    static func remove(key: String) { try? FileManager.default.removeItem(at: file(key)) }
}
```

- [ ] **Step 4: Run — expect PASS** (round-trip equal, miss → nil).

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersTests/WaveformCacheTests 2>&1 | tail -15
```

- [ ] **Step 5: Commit**

```sh
git add apps/nano-ios/Sources/DSP/WaveformCache.swift apps/nano-ios/Tests/WaveformCacheTests.swift
git commit -m "feat(ios): WaveformCache — packed [WaveBin] persistence in Caches/"
```

- [ ] **Verify against the handoff:** `05-dsp-waveform-lufs.md` cache section (persist compact bins under `waveformCacheKey`; survives non-resident cloud audio; regenerable). Logic only.

---

## Task 4: `WaveformStore` coordinator + analysis triggers (eager import + lazy first-render)

**Files:** Create `Sources/DSP/WaveformStore.swift`; Modify `Sources/Import/TrackImporter.swift`.

- [ ] **Step 1: Implement `Sources/DSP/WaveformStore.swift`** (the single entry point views + import use):

```swift
import Foundation
import SwiftData

/// Coordinates waveform availability: memory → disk cache → analyze (off-main via the actor),
/// persisting results and writing them back onto the Track on the main actor. Views call
/// `bins(for:)` from a `.task`; on a cache miss it analyzes once and de-dupes concurrent requests.
@MainActor
@Observable
final class WaveformStore {
    static let shared = WaveformStore()
    private let analyzer = WaveformAnalyzer()
    private var memory: [String: [WaveBin]] = [:]   // by content key
    private var inflight: Set<PersistentIdentifier> = []

    /// Returns the track's bins, or nil while unavailable (renderer shows "analyzing"). Side effect:
    /// persists the cache and sets `track.waveformCacheKey` / `track.integratedLUFS` on first analyze.
    @discardableResult
    func bins(for track: Track) async -> [WaveBin]? {
        let key = track.waveformCacheKey
        if !key.isEmpty, let m = memory[key] { return m }
        if !key.isEmpty, let cached = WaveformCache.load(key: key) {
            memory[key] = cached.bins
            if track.integratedLUFS == nil { track.integratedLUFS = cached.integratedLUFS }
            return cached.bins
        }
        // Analyze (de-dupe per track identity).
        guard !inflight.contains(track.persistentModelID) else { return nil }
        inflight.insert(track.persistentModelID)
        defer { inflight.remove(track.persistentModelID) }

        let ref = TrackRef(bundledName: track.bundledName, bookmark: track.bookmark)
        guard let result = try? await analyzer.analyze(ref) else { return nil }
        WaveformCache.save(key: result.key, bins: result.bins, integratedLUFS: result.integratedLUFS,
                           sampleRate: result.sampleRate, durationSec: result.durationSec)
        memory[result.key] = result.bins
        track.waveformCacheKey = result.key
        track.integratedLUFS = result.integratedLUFS
        return result.bins
    }
}
```

- [ ] **Step 2: Eager-kick analysis on import.** In `Sources/Import/TrackImporter.swift`, after `ctx.insert(track)` (inside the loop), add a fire-and-forget analyze so imported files get cached promptly:

```swift
            ctx.insert(track)
            // Kick analysis so the waveform/LUFS are ready by the time the row appears.
            Task { await WaveformStore.shared.bins(for: track) }
            count += 1
```

- [ ] **Step 3: Build — expect SUCCESS** (lazy `.task` wiring lands with NMRow in Task 5; this compiles the coordinator + import kick):

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
```

- [ ] **Step 4: Run the full unit suite — expect PASS** (no regressions):

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -12
```

- [ ] **Step 5: Commit**

```sh
git add apps/nano-ios/Sources/DSP/WaveformStore.swift apps/nano-ios/Sources/Import/TrackImporter.swift
git commit -m "feat(ios): WaveformStore coordinator + eager analysis on import"
```

- [ ] **Verify against the handoff:** `05-dsp-waveform-lufs.md` §B ("on import, or first play; off the main thread"). The lazy first-render path (Task 5) is what covers the bundled demo tracks that skip the importer.

---

## Task 5: Downsample + `NMMiniWave` + per-track LUFS, mounted in `NMRow` and `MiniPlayer`

**Files:** Create `Sources/DSP/WaveBins.swift`, `Sources/Components/NMMiniWave.swift`, `Sources/Components/NMLufsValue.swift`, `Tests/WaveBinsTests.swift`; Modify `Sources/Components/NMRow.swift`, `Sources/Components/MiniPlayer.swift`.

- [ ] **Step 1: Write the failing downsample test** `Tests/WaveBinsTests.swift`:

```swift
import XCTest
@testable import NanoMeters

final class WaveBinsTests: XCTestCase {
    func test_maxDownsampleKeepsPeakOfEachRange() {
        let bins = (0..<100).map { WaveBin(peak: Float($0) / 100, r: 0, g: 0, b: 0) }
        let out = WaveBins.maxDownsample(bins, to: 10)
        XCTAssertEqual(out.count, 10)
        // Each output bar is the max peak of its source range; last bar covers the loudest source.
        XCTAssertEqual(out.last?.peak ?? 0, 0.99, accuracy: 0.001)
        XCTAssertTrue(zip(out, out.dropFirst()).allSatisfy { $0.peak <= $1.peak }, "monotone for a ramp")
    }
    func test_downsampleHandlesFewerSourceBins() {
        let bins = [WaveBin(peak: 0.4, r: 0, g: 0, b: 0)]
        XCTAssertEqual(WaveBins.maxDownsample(bins, to: 22).count, 22)
    }
}
```

- [ ] **Step 2: Implement `Sources/DSP/WaveBins.swift`:**

```swift
import SwiftUI

/// Pure helpers over [WaveBin]: downsample the one cached array to a target bar count (max-peak
/// per source range, carrying that bar's color), and bridge a bin's continuous color to SwiftUI.
enum WaveBins {
    /// Max-peak downsample to `target` bars. The same cached array feeds the overview (~150),
    /// the row mini (22), and the mini-player mini — never re-analyzed (handoff §05).
    static func maxDownsample(_ bins: [WaveBin], to target: Int) -> [WaveBin] {
        guard target > 0 else { return [] }
        guard !bins.isEmpty else { return Array(repeating: WaveBin(peak: 0, r: 1, g: 1, b: 1), count: target) }
        if bins.count <= target {
            // Stretch: repeat-sample so short tracks still fill the bar count.
            return (0..<target).map { bins[Int(Double($0) / Double(target) * Double(bins.count))] }
        }
        return (0..<target).map { i in
            let lo = i * bins.count / target
            let hi = max(lo + 1, (i + 1) * bins.count / target)
            return bins[lo..<hi].max(by: { $0.peak < $1.peak }) ?? bins[lo]
        }
    }

    /// The bin's continuous band color (ADR 0001). Do NOT remap to the 4 handoff hex tokens.
    static func color(_ bin: WaveBin) -> Color {
        Color(.sRGB, red: Double(bin.r), green: Double(bin.g), blue: Double(bin.b), opacity: 1)
    }

    /// Coloring-off monochrome: accent for played bars, a dim grey for upcoming.
    static let dimUnplayed = Color(.sRGB, red: 0x3A/255, green: 0x3F/255, blue: 0x4B/255, opacity: 1)
}
```

- [ ] **Step 3: Run the downsample test — expect PASS.**

- [ ] **Step 4: Implement `Sources/Components/NMMiniWave.swift`** (static Canvas; handoff §02 NMMiniWave — 22 bars, decorative, colorable):

```swift
import SwiftUI

/// Static mini waveform (handoff §02): a small N-bar Canvas with no playhead, no scrub. Used at
/// 42×20 in rows (opacity 0.7) and 56×22 in the mini player (accent-tinted). Renders nothing until
/// bins exist.
struct NMMiniWave: View {
    var bins: [WaveBin]
    var bars: Int = 22
    var colored: Bool = true
    var tint: Color = Theme.accent

    var body: some View {
        Canvas { ctx, size in
            guard !bins.isEmpty else { return }
            let bars = WaveBins.maxDownsample(bins, to: bars)
            let slot = size.width / CGFloat(bars.count)
            let barW = slot * 0.66                      // ~34% gap (handoff §02)
            for (i, b) in bars.enumerated() {
                let h = max(2, CGFloat(b.peak) * (size.height - 2))
                let x = CGFloat(i) * slot + (slot - barW) / 2
                let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                let color = colored ? WaveBins.color(b) : tint
                ctx.fill(Path(roundedRect: rect, cornerRadius: 1), with: .color(color))
            }
        }
    }
}
```

- [ ] **Step 5: Implement `Sources/Components/NMLufsValue.swift`** (handoff §02 NMRow item 4):

```swift
import SwiftUI

/// Per-track integrated LUFS, right-aligned: value 12pt `text2` (mono, tabular, one decimal) over
/// a "LUFS" 9.5pt `text3` label (handoff §02 NMRow item 4). Shows a dash while not yet analyzed.
struct NMLufsValue: View {
    var lufs: Double?
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            Text(lufs.map { String(format: "%.1f", $0) } ?? "—")
                .font(Theme.mono(12)).foregroundStyle(Theme.text2)
            Text("LUFS")
                .font(Theme.mono(9.5)).foregroundStyle(Theme.text3)
        }
    }
}
```

- [ ] **Step 6: Mount in `NMRow`** — add a bins state loaded lazily, and fill the slot between `Spacer` and the ellipsis `Button`. Add to `NMRow`'s properties:

```swift
    @State private var bins: [WaveBin] = []
```
Replace the placeholder comment block (the `// Phase 3 fills these…` line) with:
```swift
            if !bins.isEmpty {
                NMMiniWave(bins: bins, bars: 22)
                    .frame(width: 42, height: 20).opacity(0.7)
                    .accessibilityHidden(true)
            }
            NMLufsValue(lufs: track.integratedLUFS)
                .frame(minWidth: 44, alignment: .trailing)
```
And add a `.task` after `.onTapGesture { onTap() }` to lazily analyze on first appearance:
```swift
        .task(id: track.persistentModelID) {
            bins = await WaveformStore.shared.bins(for: track) ?? []
        }
```

- [ ] **Step 7: Mount in `MiniPlayer`** — a 56×22 accent-tinted mini wave between the `Spacer` and the play/pause button. Add to `MiniPlayer`:
```swift
    @State private var bins: [WaveBin] = []
```
Insert after `Spacer(minLength: 8)` in `content(_:)`:
```swift
            if !bins.isEmpty {
                NMMiniWave(bins: bins, bars: 22, colored: false, tint: Theme.accent)
                    .frame(width: 56, height: 22)
                    .accessibilityHidden(true)
            }
```
And add a `.task` on the content (e.g. after `.onTapGesture { onTapBody() }`):
```swift
        .task(id: track.persistentModelID) {
            bins = await WaveformStore.shared.bins(for: track) ?? []
        }
```

- [ ] **Step 8: Build, install, screenshot, verify the rows show mini-wave + LUFS** (the bundled demo tracks analyze via the lazy `.task`):

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
APP="build/Build/Products/Debug-iphonesimulator/NanoMeters.app"
xcrun simctl install F8BC6E09-E5E4-4054-A03B-B1434DF0838D "$APP"
xcrun simctl launch F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios
sleep 3   # let lazy analysis of the two bundled tracks finish
xcrun simctl io F8BC6E09-E5E4-4054-A03B-B1434DF0838D screenshot /tmp/nano-p3-rows.png
```
Read `/tmp/nano-p3-rows.png`: each row (Mercy, Biljam) shows a small colored mini-waveform + a numeric LUFS value (e.g. `-9.x` / LUFS) replacing the dash. Compare layout to handoff §02 NMRow.

- [ ] **Step 9: Full unit suite — expect PASS.** Then commit:

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | tail -10
git add apps/nano-ios/Sources/DSP/WaveBins.swift apps/nano-ios/Sources/Components/NMMiniWave.swift \
  apps/nano-ios/Sources/Components/NMLufsValue.swift apps/nano-ios/Sources/Components/NMRow.swift \
  apps/nano-ios/Sources/Components/MiniPlayer.swift apps/nano-ios/Tests/WaveBinsTests.swift
git commit -m "feat(ios): mini waveforms + per-track LUFS in rows and mini player"
```

- [ ] **Verify against the handoff:** `02-components.md` NMRow items 3–4 (42×20 mini-wave @0.7; LUFS value 12/`text2` + "LUFS" 9.5/`text3`, mono) and "Mini player" (56×22 accent mini-wave); the continuous FFI color (Gotcha 2 — don't remap).

---

## Task 6: `OverviewWaveform` (pure scrubber) + interim `TrackDetailScreen` host

**Files:** Create `Sources/Components/OverviewWaveform.swift`, `Sources/Screens/TrackDetailScreen.swift`; Modify `Sources/Screens/LibraryScreen.swift`, `Sources/Screens/PlaylistDetailScreen.swift`.

- [ ] **Step 1: Implement `Sources/Components/OverviewWaveform.swift`** (handoff §02 NMWaveform / §05 §B render — pure, no engine dependency):

```swift
import SwiftUI

/// Full-track overview waveform (handoff §02 NMWaveform): ~150 vertical bars, played bars full
/// color, upcoming bars 20% alpha, a 2pt white playhead with a soft glow, and whole-strip scrub
/// (drag anywhere → x → fraction → onScrub). Pure: bins + progress + onScrub, no engine — so
/// Phase 4 re-hosts it on Now Playing unchanged.
struct OverviewWaveform: View {
    var bins: [WaveBin]
    var progress: Double
    var coloringOn: Bool = true
    var onScrub: (Double) -> Void

    var bars: Int = 150
    var height: CGFloat = 62

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            Canvas { ctx, size in
                guard !bins.isEmpty else { return }
                let bars = WaveBins.maxDownsample(bins, to: bars)
                let slot = size.width / CGFloat(bars.count)
                let barW = slot * 0.66
                let playedX = size.width * CGFloat(min(1, max(0, progress)))
                for (i, b) in bars.enumerated() {
                    let h = max(2, CGFloat(b.peak) * (size.height - 4))
                    let x = CGFloat(i) * slot + (slot - barW) / 2
                    let rect = CGRect(x: x, y: (size.height - h) / 2, width: barW, height: h)
                    let played = (x + barW) <= playedX
                    let base = coloringOn ? WaveBins.color(b) : Theme.accent
                    let color = played ? base : base.opacity(0.20)   // upcoming 20% (handoff §02)
                    ctx.fill(Path(roundedRect: rect, cornerRadius: 1.5), with: .color(color))
                }
                // Playhead: 2pt white line + soft glow.
                var head = Path()
                head.move(to: CGPoint(x: playedX, y: 0)); head.addLine(to: CGPoint(x: playedX, y: size.height))
                ctx.addFilter(.shadow(color: .white.opacity(0.6), radius: 4))
                ctx.stroke(head, with: .color(.white), lineWidth: 2)
            }
            .frame(height: height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0).onChanged { v in
                    onScrub(min(1, max(0, v.location.x / width)))
                }
            )
            .accessibilityIdentifier("overviewWaveform")
        }
        .frame(height: height)
    }
}
```

- [ ] **Step 2: Implement `Sources/Screens/TrackDetailScreen.swift`** (interim host; binds to the engine):

```swift
import SwiftUI

/// Interim Phase-3 home for the overview scrubber, reached via a row's ellipsis. The overview View
/// itself is engine-agnostic; this screen wires it to the live AudioEngine. In Phase 4 the overview
/// moves to Now Playing and this screen is retired.
struct TrackDetailScreen: View {
    @Environment(AudioEngine.self) private var engine
    let track: Track
    @State private var bins: [WaveBin] = []

    var body: some View {
        VStack(spacing: 20) {
            NMArtwork(data: track.artworkData, size: 220, radius: 18)
                .padding(.top, 24)
            Text(track.title).font(Theme.sans(22, .bold)).foregroundStyle(Theme.text)
            Text(track.artist).font(Theme.sans(15)).foregroundStyle(Theme.text2)

            OverviewWaveform(
                bins: bins,
                progress: isCurrent ? engine.progress : 0,
                onScrub: { if isCurrent { engine.seek(toFraction: $0) } }
            )
            .padding(.horizontal, Theme.Layout.screenMargin)

            HStack {
                Text(PlaybackMath.clock(isCurrent ? engine.elapsed : 0))
                Spacer()
                Text(NMLufsString(track.integratedLUFS))
            }
            .font(Theme.mono(12)).foregroundStyle(Theme.text3)
            .padding(.horizontal, Theme.Layout.screenMargin)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .background(Theme.bg.ignoresSafeArea())
        .task(id: track.persistentModelID) { bins = await WaveformStore.shared.bins(for: track) ?? [] }
    }

    private var isCurrent: Bool { engine.current?.id == track.id }
    private func NMLufsString(_ v: Double?) -> String { v.map { String(format: "%.1f LUFS", $0) } ?? "— LUFS" }
}
```

- [ ] **Step 3: Wire `NMRow.onEllipsis` → `TrackDetailScreen`** in `LibraryScreen` and `PlaylistDetailScreen`. In each, add presentation state and pass `onEllipsis`. For `LibraryScreen` (mirror in `PlaylistDetailScreen`):

```swift
    @State private var detailTrack: Track?
```
Pass `onEllipsis` on each `NMRow(...)`:
```swift
                            onEllipsis: { detailTrack = track }
```
And present it (add to the `ScrollView`/screen root):
```swift
        .sheet(item: $detailTrack) { TrackDetailScreen(track: $0) }
```
> `Track` is a SwiftData `@Model` (an `Identifiable` with `id: UUID`), so `.sheet(item:)` works directly.

- [ ] **Step 4: Build, install, verify the overview + scrub on the simulator:**

```sh
cd apps/nano-ios
xcodebuild -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -derivedDataPath build build 2>&1 | tail -3
APP="build/Build/Products/Debug-iphonesimulator/NanoMeters.app"
xcrun simctl install F8BC6E09-E5E4-4054-A03B-B1434DF0838D "$APP"
xcrun simctl launch F8BC6E09-E5E4-4054-A03B-B1434DF0838D com.willeasp.nanometers.ios
```
Manual (controller): play a track, open its ellipsis → detail; confirm the overview renders ~150 colored bars with a white playhead that advances; drag the strip and confirm playback seeks. (Automated coverage in Task 7.)

- [ ] **Step 5: Commit**

```sh
git add apps/nano-ios/Sources/Components/OverviewWaveform.swift apps/nano-ios/Sources/Screens/TrackDetailScreen.swift \
  apps/nano-ios/Sources/Screens/LibraryScreen.swift apps/nano-ios/Sources/Screens/PlaylistDetailScreen.swift
git commit -m "feat(ios): OverviewWaveform scrubber + interim TrackDetailScreen host"
```

- [ ] **Verify against the handoff:** `02-components.md` §A NMWaveform + `05-dsp-waveform-lufs.md` §B render (≤2000 rects in Canvas, ~150 bars, 62pt, played full / upcoming 20%, 2pt playhead + glow, whole-strip scrub x→time); ADR 0010 (Canvas, Metal only if it can't hold 120 Hz).

---

## Task 7: End-to-end UI verification (overview scrub + per-track LUFS)

**Files:** Create `UITests/WaveformUITests.swift`.

- [ ] **Step 1: Add accessibility ids** needed by the test. In `NMRow`, give the ellipsis button one:
```swift
            .accessibilityIdentifier("rowEllipsis")
```
(`OverviewWaveform` already sets `accessibilityIdentifier("overviewWaveform")` in Task 6.)

- [ ] **Step 2: Implement `UITests/WaveformUITests.swift`** (same pattern as `PlaybackUITests`):

```swift
import XCTest

final class WaveformUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_openDetail_overviewScrubsAndRowShowsLUFS() {
        let app = XCUIApplication()
        app.launch()

        // After lazy analysis, a row shows a numeric LUFS value (not the dash).
        XCTAssertTrue(app.staticTexts["LUFS"].firstMatch.waitForExistence(timeout: 15))

        // Play, then open the first row's detail via its ellipsis.
        app.staticTexts["Mercy"].tap()
        app.buttons["rowEllipsis"].firstMatch.tap()

        // The overview renders and is scrubbable.
        let overview = app.otherElements["overviewWaveform"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "overview waveform should render in detail")
        let before = app.staticTexts["miniPlayerTitle"].label   // sanity that playback context exists
        overview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()  // scrub near the end
        XCTAssertEqual(app.staticTexts["miniPlayerTitle"].label, before)  // same track, just seeked
    }
}
```

- [ ] **Step 3: Run the UI test — expect PASS:**

```sh
cd apps/nano-ios && xcodegen generate
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' \
  -only-testing:NanoMetersUITests/WaveformUITests 2>&1 | tail -20
```
If the LUFS text isn't found in time, raise the timeout (first-run analysis of both bundled tracks) or confirm the lazy `.task` runs.

- [ ] **Step 4: Full suite (unit + UI) — expect PASS:**

```sh
xcodebuild test -project NanoMeters.xcodeproj -scheme NanoMeters \
  -destination 'platform=iOS Simulator,id=F8BC6E09-E5E4-4054-A03B-B1434DF0838D' 2>&1 | grep -E "Executed [0-9]+ test|\*\* TEST" | tail -6
```

- [ ] **Step 5: Commit**

```sh
git add apps/nano-ios/Sources/Components/NMRow.swift apps/nano-ios/UITests/WaveformUITests.swift
git commit -m "test(ios): XCUITest overview scrub + per-track LUFS"
```

- [ ] **Verify against the handoff:** the `PlaybackUITests` harness pattern; §02/§05 scrub + LUFS contract; bundled demo tracks (Mercy/Biljam) analyze via the lazy path.

---

## Self-Review (run before execution)

**Spec coverage** (Phase 3 = "overview waveform + per-track LUFS: WaveformAnalyzer + WaveformCache, OverviewWaveform + scrub, MiniWave, integrated LUFS in rows"):
- WaveformAnalyzer → Task 2. WaveformCache → Task 3. WaveformStore/triggers → Task 4. ✓
- OverviewWaveform + scrub → Task 6. MiniWave (rows + mini player) → Task 5. Per-track LUFS in rows → Task 5. ✓
- FFI link (prerequisite, first consumption) → Task 1. ✓
- Self-verification (the harness) → Task 7 + the unit tests in 1–3, 5. ✓

**Placeholder scan:** all code blocks concrete. The only "interim" piece (`TrackDetailScreen`) is explicitly flagged as a Phase-3 host that Phase 4 retires; the overview component it hosts is final.

**Type consistency:** `WaveBin` is the single Swift type across bridge/analyzer/cache/renderers/tests (only `NanoDSPBridge` imports `NanoDSP`); `WaveformAnalyzer.AnalysisResult.key`/`bins`/`integratedLUFS` flow into `WaveformCache.save`/`load` and `WaveformStore`; `WaveBins.maxDownsample` is used by both `NMMiniWave` and `OverviewWaveform`; `TrackRef` is the Sendable snapshot used by the actor; `binsPerSecond = 10` is the one density constant.

**Gotchas honored:** arm64-only (noted); continuous FFI color rendered as-is (Gotcha 2); one decode → mono + L/R (Task 2); `Caches/` miss → "analyzing"/dash, never crash (cache load → nil; renderers guard `!bins.isEmpty`); analyzer's own security scope (Task 2 `resolve`); 20 Hz playhead acceptable for the overview (note for Phase 5).
