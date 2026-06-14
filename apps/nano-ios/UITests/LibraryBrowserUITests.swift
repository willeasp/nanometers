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

    /// The headline ask: a left-to-right edge swipe pops the stack (interactive swipe-back), even though
    /// the system nav bar is hidden. Proven by re-revealing the parent level's folder row — which only
    /// exists at the source level, not inside the folder. If the swipe-back shim were a no-op, the swipe
    /// would do nothing and the folder row would never come back.
    @MainActor
    func test_edgeSwipe_popsBackToParent() {
        let app = XCUIApplication()
        app.launch()

        // Drill: root → source → into the "On My iPhone" root folder.
        let sourceRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10), "Root should show the local source row")
        sourceRow.tap()

        let folderRow = app.descendants(matching: .any)["folderRow-On My iPhone"].firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 10), "Source level should show the root folder row")
        folderRow.tap()

        // Inside the folder: a demo track is visible.
        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 5),
                      "Folder should contain demo track 'Biljam'")

        // Edge swipe left→right from the screen's left edge.
        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: target)

        // Popped back to the source level: the parent's folder row is visible again.
        XCTAssertTrue(folderRow.waitForExistence(timeout: 5),
                      "Edge swipe-back should pop to the source level (folder row visible again)\n\(app.debugDescription)")
    }

    /// Scoped search clears on navigation (handoff §04): toggling search at a level, drilling away, and
    /// popping back must NOT reveal a stale search field — even though each level now owns its search state.
    @MainActor
    func test_scopedSearch_clearsWhenLeavingLevel() {
        let app = XCUIApplication()
        app.launch()

        let sourceRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10), "Root should show the local source row")
        sourceRow.tap()

        // Toggle scoped search at the source level (empty query keeps folder rows tappable).
        let toggle = app.descendants(matching: .any)["searchToggle"].firstMatch
        XCTAssertTrue(toggle.waitForExistence(timeout: 10), "Source level should offer a search toggle")
        toggle.tap()
        XCTAssertTrue(app.textFields["scopedSearchField"].waitForExistence(timeout: 5),
                      "Scoped search field should appear after toggling")

        // Drill into a folder, then edge-swipe back to the source level.
        let folderRow = app.descendants(matching: .any)["folderRow-On My iPhone"].firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 5))
        folderRow.tap()
        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 5), "Should be inside the folder")

        let edge = app.coordinate(withNormalizedOffset: CGVector(dx: 0.0, dy: 0.5))
        let target = app.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5))
        edge.press(forDuration: 0.1, thenDragTo: target)

        // Back at the source level — search must have cleared (field gone).
        XCTAssertTrue(folderRow.waitForExistence(timeout: 5), "Should be back at the source level")
        XCTAssertFalse(app.textFields["scopedSearchField"].exists,
                       "Scoped search should clear when leaving the level\n\(app.debugDescription)")
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
