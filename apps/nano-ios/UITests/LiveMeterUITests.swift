import XCTest
import UIKit

/// Regression guard for the live-meter freeze: a `Canvas` inside a `TimelineView(.animation)` only
/// re-renders per tick if its renderer actually READS the schedule date. The spectrum had
/// `{ _ in Canvas {…} }` (date ignored) → SwiftUI treated the Canvas as unchanged and never re-ran it,
/// so it sat frozen during playback. This crops the meter across ~1 s of playback and asserts it is NOT
/// pixel-identical the whole time.
///
/// NOTE: only the spectrum is checked this way. The goniometer's smooth-scan rate can't be measured by
/// screenshots — XCUITest throttles captures below 10 Hz and doesn't render audio at real wall-clock,
/// so the cursor (which trails the audio head in real time) stalls under the harness even though it runs
/// at the full display rate on device. That path is covered deterministically by `ScopeScanTests`.
final class LiveMeterUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_spectrumAnimatesDuringPlayback() throws {
        try assertMeterAnimates(id: "spectrum")
    }

    @MainActor
    private func assertMeterAnimates(id: String) throws {
        let app = XCUIApplication()
        app.launchArguments += ["-autoplay", "-expand", "-flipAnalysis", "-modules", "scope,gonio,spectrum"]
        app.launch()
        let meter = app.otherElements[id]
        XCTAssertTrue(meter.waitForExistence(timeout: 12), "\(id) should be on the flipped B-side")
        Thread.sleep(forTimeInterval: 1.0)               // let playback + the meter warm up

        let frame = meter.frame
        XCTAssertGreaterThan(frame.width * frame.height, 100, "\(id) has no on-screen area")
        // A live (60 Hz) meter changes on essentially every sample; the frozen-bug version only updated on
        // sparse external invalidations (~3 distinct frames/s), which still "moves" a little but reads as
        // stuck. So we require MOST samples to be distinct, not merely "not all identical".
        var crops: [Data] = []
        for _ in 0..<10 {
            if let data = Self.crop(XCUIScreen.main.screenshot().image, to: frame) { crops.append(data) }
            Thread.sleep(forTimeInterval: 0.12)
        }
        XCTAssertGreaterThan(crops.count, 5, "failed to capture \(id) crops")
        let distinct = Set(crops).count
        XCTAssertGreaterThanOrEqual(distinct, 8, "\(id) updated only \(distinct)/\(crops.count) samples — it is not animating per-frame (regression)")
    }

    /// Crop a full-screen screenshot (pixels, at the screen scale) to an element's point-rect.
    private static func crop(_ image: UIImage, to rect: CGRect) -> Data? {
        guard let cg = image.cgImage else { return nil }
        let s = image.scale
        let px = CGRect(x: rect.origin.x * s, y: rect.origin.y * s,
                        width: rect.size.width * s, height: rect.size.height * s)
        guard let c = cg.cropping(to: px) else { return nil }
        return UIImage(cgImage: c).pngData()
    }
}
