import XCTest

final class WaveformUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_openDetail_overviewScrubsAndRowShowsLUFS() {
        let app = XCUIApplication()
        app.launch()

        // After lazy analysis, a row shows a numeric LUFS value (the "LUFS" label appears).
        XCTAssertTrue(app.staticTexts["LUFS"].firstMatch.waitForExistence(timeout: 15))

        // Play, then open the first row's detail via its ellipsis.
        app.staticTexts["Mercy"].tap()
        app.buttons["rowEllipsis"].firstMatch.tap()

        // The overview renders and is scrubbable.
        let overview = app.otherElements["overviewWaveform"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "overview waveform should render in detail")
        let before = app.staticTexts["miniPlayerTitle"].label   // playback context exists
        overview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()  // scrub near the end
        XCTAssertEqual(app.staticTexts["miniPlayerTitle"].label, before)  // same track, just seeked
    }
}
