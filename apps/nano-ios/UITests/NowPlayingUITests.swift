import XCTest

final class NowPlayingUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_settingsTrackOverviewTogglesScrubber() {
        let app = XCUIApplication()
        app.launch()
        // Open Settings via the gear button.
        let gear = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Settings gear button should exist")
        gear.tap()
        // Assert all three toggle rows are present.
        XCTAssertTrue(app.switches["Close-up (DJ scroll)"].waitForExistence(timeout: 5), "Close-up toggle should be in Settings")
        XCTAssertTrue(app.switches["Track overview"].exists, "Track overview toggle should be in Settings")
        XCTAssertTrue(app.switches["Frequency coloring"].exists, "Frequency coloring toggle should be in Settings")
        // Done dismisses the sheet.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.switches["Track overview"].waitForExistence(timeout: 3), "Settings sheet should dismiss after Done")
    }

    @MainActor
    func test_miniPlayerExpandsAndChevronCollapses() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 10))
        app.staticTexts["Mercy"].tap()                       // dock the mini player

        // The player is ONE persistent view morphing on a 0…1 progress, so present/dismiss are
        // checked via INTERACTIVITY (the mini is hittable only when collapsed, the chevron only when
        // expanded) rather than existence — every element is always in the tree.
        let miniBody = app.buttons["miniPlayerBody"].firstMatch
        XCTAssertTrue(miniBody.waitForExistence(timeout: 5), "mini player should appear after tapping a track")
        miniBody.tap()                                       // tap mini body → expand to Now Playing

        let dismiss = app.buttons["npDismiss"]
        XCTAssertTrue(dismiss.waitForExistence(timeout: 5))
        expect(dismiss.isHittable && !miniBody.isHittable, within: 5, "Now Playing should be expanded")

        dismiss.tap()                                        // chevron.down → collapse
        expect(miniBody.isHittable, within: 5, "mini player should return after collapsing")
    }

    /// Poll a UI condition (spring animations settle asynchronously).
    @MainActor
    private func expect(_ condition: @escaping @autoclosure () -> Bool, within timeout: TimeInterval, _ message: String) {
        let exp = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in condition() }, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: timeout), .completed, message)
    }
}
