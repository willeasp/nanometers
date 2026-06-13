import XCTest

final class NowPlayingUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    @MainActor
    func test_settingsAnalysisGroupPresent() {
        let app = XCUIApplication()
        app.launch()
        // Open Settings via the Library gear.
        let gear = app.buttons["settingsButton"].firstMatch
        XCTAssertTrue(gear.waitForExistence(timeout: 5), "Settings gear button should exist")
        gear.tap()
        // The Analysis group: two toggles + the close-up window segmented control.
        XCTAssertTrue(app.switches["Frequency coloring"].waitForExistence(timeout: 5), "Frequency coloring toggle")
        XCTAssertTrue(app.switches["Track overview scrubber"].exists, "Track overview scrubber toggle")
        XCTAssertTrue(app.buttons["4s"].exists, "close-up window segmented control present")
        // Done dismisses the sheet.
        app.buttons["Done"].firstMatch.tap()
        XCTAssertFalse(app.switches["Frequency coloring"].waitForExistence(timeout: 3), "Settings should dismiss after Done")
    }

    @MainActor
    func test_nowPlayingGearOpensSettings() {
        let app = XCUIApplication()
        app.launchArguments += ["-autoplay", "-expand"]
        app.launch()
        XCTAssertTrue(app.otherElements["nowPlaying"].waitForExistence(timeout: 8), "Now Playing should auto-open")
        app.buttons["npSettings"].tap()
        XCTAssertTrue(app.switches["Frequency coloring"].waitForExistence(timeout: 5),
                      "the Now Playing gear opens the Analysis settings")
        app.buttons["Done"].firstMatch.tap()
    }

    @MainActor
    func test_moduleSwitcherTogglesAndKeepsOne() {
        let app = XCUIApplication()
        app.launchArguments += ["-autoplay", "-expand", "-modules", "scope"]
        app.launch()
        XCTAssertTrue(app.otherElements["nowPlaying"].waitForExistence(timeout: 8), "Now Playing should auto-open")
        app.descendants(matching: .any)["npArtwork"].tap()             // flip to the analysis B-side
        XCTAssertTrue(app.otherElements["closeUpWaveform"].waitForExistence(timeout: 5), "scope is on by default")

        let modScope = app.buttons["modScope"]
        XCTAssertTrue(modScope.waitForExistence(timeout: 5), "module switcher should be present on the B-side")

        // Min-one: tapping the only-on module is a no-op — the scope stays.
        modScope.tap()
        XCTAssertTrue(app.otherElements["closeUpWaveform"].exists, "min-one: the last module can't be turned off")

        // Enabling the goniometer adds it.
        app.buttons["modGonio"].tap()
        XCTAssertTrue(app.otherElements["goniometer"].waitForExistence(timeout: 5), "goniometer appears when enabled")
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
