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
        // The Now Playing title shows the track (the mini player is gone while NP is up).
        let before = app.staticTexts["npTitle"].label
        overview.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)).tap()  // scrub near the end
        XCTAssertEqual(app.staticTexts["npTitle"].label, before)  // same track, just seeked (not skipped)
    }

    @MainActor
    func test_flipRevealsCloseUpScopeAndBack() {
        let app = XCUIApplication()
        app.launchArguments += ["-autoplay", "-expand"]   // dock a track + open Now Playing on the cover
        app.launch()

        XCTAssertTrue(app.otherElements["nowPlaying"].waitForExistence(timeout: 8), "Now Playing should auto-open")
        let artwork = app.descendants(matching: .any)["npArtwork"]
        XCTAssertTrue(artwork.waitForExistence(timeout: 5), "the cover front should be present")
        artwork.tap()                                                  // flip to the analysis B-side

        XCTAssertTrue(app.otherElements["analysisArea"].waitForExistence(timeout: 5), "flip reveals the analysis rack")
        XCTAssertTrue(app.otherElements["closeUpWaveform"].waitForExistence(timeout: 5),
                      "the close-up scope renders (default module)")

        app.buttons["npFlipBack"].tap()                                // flip back to the cover
        expect(artwork.isHittable, within: 5, "the cover front should be interactive again after flipping back")
    }

    /// Poll a UI condition (spring animations settle asynchronously).
    @MainActor
    private func expect(_ condition: @escaping @autoclosure () -> Bool, within timeout: TimeInterval, _ message: String) {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed, message)
    }
}
