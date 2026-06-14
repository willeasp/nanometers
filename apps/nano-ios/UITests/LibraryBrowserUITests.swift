import XCTest

/// UI smoke-tests for the Library folder browser: root → source → folder → tracks, tab re-tap
/// pops to root, and All Songs lists the demo tracks. Runs against the migrated local source
/// ("On My iPhone") seeded with the 2 bundled demo tracks (Biljam, Mercy).
final class LibraryBrowserUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    /// Drill from root into the local source → root folder → verify demo tracks; tab re-tap pops back.
    @MainActor
    func test_root_showsAllSongsAndLocalSource_drillAndBack() {
        let app = XCUIApplication()
        app.launch()

        // Root: "All Songs" row must appear.
        XCTAssertTrue(app.staticTexts["All Songs"].waitForExistence(timeout: 10),
                      "Root should show 'All Songs'")

        // Root: the On My iPhone source row (accessibilityIdentifier "sourceRow-local").
        let sourceRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 5),
                      "Root should show the local source row (sourceRow-local)")
        sourceRow.tap()

        // Inside the source: either the breadcrumb or "On My iPhone" folder row appears.
        let folderRow = app.descendants(matching: .any)["folderRow-On My iPhone"].firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 10),
                      "Source level should show root folder 'On My iPhone'\n\(app.debugDescription)")

        // Drill into the root folder "On My iPhone".
        folderRow.tap()

        // The demo tracks should appear.
        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 5),
                      "Folder should contain demo track 'Biljam'\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 5),
                      "Folder should contain demo track 'Mercy'")

        // Tab re-tap: tap "Library" tab button to pop back to the Library root.
        app.buttons["Library"].tap()
        XCTAssertTrue(app.staticTexts["All Songs"].waitForExistence(timeout: 5),
                      "Tab re-tap should pop back to root showing 'All Songs'")
    }

    /// All Songs lists both demo tracks.
    @MainActor
    func test_allSongs_listsDemoTracks() {
        let app = XCUIApplication()
        app.launch()

        // Wait for the source row before tapping All Songs — signals migration + index rebuild done.
        let sourceRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10),
                      "Root should show the local source row before tapping All Songs")

        app.staticTexts["All Songs"].tap()

        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 10),
                      "All Songs should list 'Biljam'\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 5),
                      "All Songs should list 'Mercy'")
    }
}
