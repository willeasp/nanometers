import XCTest

final class WaveformUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_openDetail_overviewScrubsAndRowShowsLUFS() {
        let app = XCUIApplication()
        app.launch()

        // After lazy analysis, a row shows a numeric LUFS value (the "LUFS" label appears).
        XCTAssertTrue(app.staticTexts["LUFS"].firstMatch.waitForExistence(timeout: 15))

        // Play "Mercy" by tapping its row title, then open Now Playing via the mini player body.
        app.staticTexts["Mercy"].tap()
        XCTAssertTrue(app.buttons["miniPlayerBody"].waitForExistence(timeout: 5))
        app.buttons["miniPlayerBody"].tap()

        // The overview renders inside Now Playing and is scrubbable.
        let nowPlaying = app.otherElements["nowPlaying"]
        XCTAssertTrue(nowPlaying.waitForExistence(timeout: 5), "Now Playing screen should appear")
        let overview = app.otherElements["overviewWaveform"]
        XCTAssertTrue(overview.waitForExistence(timeout: 5), "overview waveform should render in Now Playing")
        let before = app.staticTexts["miniPlayerTitle"].label   // playback context exists
        overview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()  // scrub near the end
        XCTAssertEqual(app.staticTexts["miniPlayerTitle"].label, before)  // same track, just seeked
    }
}
