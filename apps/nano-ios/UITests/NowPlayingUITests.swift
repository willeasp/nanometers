import XCTest

final class NowPlayingUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_miniPlayerTapPresentsAndChevronDismissesNowPlaying() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 10))
        app.staticTexts["Mercy"].tap()                       // dock the mini player

        // Tap the miniPlayerBody button (artwork+title area of the mini player) to open Now Playing.
        // Using firstMatch because the button may appear at the bottom of the Z-stack which XCTest
        // reports slightly outside the visible window rect (but synthetic taps still land correctly).
        let miniBody = app.buttons.matching(identifier: "miniPlayerBody").firstMatch
        XCTAssertTrue(miniBody.waitForExistence(timeout: 5), "Mini player body should appear after tapping a track")
        miniBody.tap()                                       // tap mini body → present NP

        let np = app.otherElements["nowPlaying"]
        XCTAssertTrue(np.waitForExistence(timeout: 5), "Now Playing should present")

        app.buttons["npDismiss"].tap()                       // chevron.down dismiss
        XCTAssertFalse(np.waitForExistence(timeout: 3), "Now Playing should dismiss")
    }
}
