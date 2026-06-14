import XCTest

final class WaveformUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_openDetail_overviewScrubsAndRowShowsLUFS() {
        let app = XCUIApplication()
        app.launch()

        // Library root is a folder browser — navigate into All Songs to reach the seeded tracks.
        XCTAssertTrue(app.staticTexts["All Songs"].waitForExistence(timeout: 10),
                      "Root should show 'All Songs'")
        app.staticTexts["All Songs"].tap()

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
        // The Now Playing title shows the track (the mini player is gone while NP is up).
        let before = app.staticTexts["npTitle"].label
        overview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()  // scrub near the end
        XCTAssertEqual(app.staticTexts["npTitle"].label, before)  // same track, just seeked (not skipped)
    }

    @MainActor
    func test_closeUpAppearsWhenZoomWaveEnabled() {
        let app = XCUIApplication()
        // -autoplay docks a track, -expand opens Now Playing; -zoomWave YES lands in the UserDefaults
        // argument domain so @AppStorage("zoomWave") reads true without touching app code.
        app.launchArguments += ["-autoplay", "-expand", "-zoomWave", "YES"]
        app.launch()

        XCTAssertTrue(app.otherElements["nowPlaying"].waitForExistence(timeout: 8),
                      "Now Playing should auto-open")
        XCTAssertTrue(app.otherElements["closeUpWaveform"].waitForExistence(timeout: 5),
                      "close-up should render when zoomWave is on")
    }
}
