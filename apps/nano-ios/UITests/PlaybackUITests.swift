import XCTest

/// End-to-end UI smoke test of the playback chain: tapping a seeded track docks the mini player,
/// the transport buttons drive it, and Next advances to the next track. Runs against the real app
/// on the simulator (the two bundled demo tracks seed on first launch). This is the tap-level
/// verification the headless unit tests can't express; pair it with `AudioEngineTests` (which
/// proves audio actually renders) for full coverage without a human in the loop.
final class PlaybackUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    @MainActor
    func test_tapTrackDocksMiniPlayer_transportAndNextWork() {
        let app = XCUIApplication()
        app.launch()

        // Library root is a folder browser — navigate into All Songs to reach the seeded tracks.
        XCTAssertTrue(app.staticTexts["All Songs"].waitForExistence(timeout: 10),
                      "Root should show 'All Songs'")
        app.staticTexts["All Songs"].tap()

        let mercy = app.staticTexts["Mercy"]
        XCTAssertTrue(mercy.waitForExistence(timeout: 10), "All Songs should show the seeded 'Mercy' row")
        mercy.tap()

        // Tapping the row docks the mini player and starts playback (button labeled "Pause").
        let playPause = app.buttons["miniPlayerPlayPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 5), "mini player should dock after tapping a track")
        XCTAssertEqual(playPause.label, "Pause", "should be playing immediately after tap")

        // The mini player shows the tapped track.
        let title = app.staticTexts["miniPlayerTitle"]
        XCTAssertTrue(title.waitForExistence(timeout: 3))
        XCTAssertEqual(title.label, "Mercy")

        // Pause flips the control to "Play".
        playPause.tap()
        XCTAssertEqual(app.buttons["miniPlayerPlayPause"].label, "Play", "pause should flip control to Play")

        // Resume, then Next advances to the second seeded track.
        app.buttons["miniPlayerPlayPause"].tap()   // resume → "Pause"
        app.buttons["miniPlayerNext"].tap()
        XCTAssertEqual(title.label, "Biljam", "Next should advance the mini player to the second track")
    }
}
