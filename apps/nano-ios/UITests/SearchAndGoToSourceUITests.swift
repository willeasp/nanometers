import XCTest

/// XCUITest for Phase 3 features: scoped search (filtering within a folder) and
/// Go-to-Source (⋯ context menu navigates Library to the file's folder).
/// Runs against the Nano sim seeded with the 2 demo tracks (Biljam, Mercy) under
/// the local source "On My iPhone".
final class SearchAndGoToSourceUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    // MARK: - Test 1: Scoped search filters within a folder

    /// Drill into the local source's root folder, activate scoped search, type "Mercy",
    /// assert "Mercy" appears and "Biljam" does NOT.
    @MainActor
    func test_scopedSearch_filtersWithinFolder() {
        let app = XCUIApplication()
        app.launch()

        // Wait for Library root to appear (signals migration + index ready).
        let sourceRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10),
                      "Root should show the local source row (sourceRow-local)")
        sourceRow.tap()

        // Inside the source — drill into the "On My iPhone" root folder.
        let folderRow = app.descendants(matching: .any)["folderRow-On My iPhone"].firstMatch
        XCTAssertTrue(folderRow.waitForExistence(timeout: 10),
                      "Source level should show root folder row\n\(app.debugDescription)")
        folderRow.tap()

        // The folder now shows both demo tracks.
        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 5),
                      "Folder should contain demo track 'Biljam' before searching")

        // Tap the search toggle to open the scoped search field.
        let searchToggle = app.buttons["searchToggle"].firstMatch
        XCTAssertTrue(searchToggle.waitForExistence(timeout: 5),
                      "Search toggle button should be visible at folder level\n\(app.debugDescription)")
        searchToggle.tap()

        // The scoped search field should appear.
        let searchField = app.textFields["scopedSearchField"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "Scoped search field should appear after tapping searchToggle\n\(app.debugDescription)")

        // Tap the field to focus it, then type the query.
        searchField.tap()
        searchField.typeText("Mercy")

        // "Mercy" should appear in the results.
        XCTAssertTrue(app.staticTexts["Mercy"].waitForExistence(timeout: 5),
                      "Search results should show 'Mercy'\n\(app.debugDescription)")

        // "Biljam" should NOT appear (short timeout — we're asserting absence).
        XCTAssertFalse(app.staticTexts["Biljam"].waitForExistence(timeout: 2),
                       "Search results should NOT show 'Biljam' when querying 'Mercy'")
    }

    // MARK: - Test 2: Go-to-Source from context menu navigates + shows breadcrumb

    /// Tap All Songs, open a track's ⋯ menu, tap "Go to Source", then assert the
    /// Library shows the folder view (breadcrumb exists) and the track title is visible.
    /// (The highlight wash fades on a timer; we only assert presence, not the wash itself.)
    @MainActor
    func test_goToSource_fromContextMenu_navigatesAndHighlights() {
        let app = XCUIApplication()
        app.launch()

        // Wait for Library root, then tap All Songs.
        let sourceRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10),
                      "Root should show the local source row before tapping All Songs")

        app.staticTexts["All Songs"].tap()

        // Both demo tracks should appear in All Songs.
        XCTAssertTrue(app.staticTexts["Biljam"].waitForExistence(timeout: 10),
                      "All Songs should list 'Biljam'\n\(app.debugDescription)")

        // Open the ⋯ context menu on the first track row.
        let ellipsisButtons = app.buttons["rowEllipsis"]
        XCTAssertTrue(ellipsisButtons.firstMatch.waitForExistence(timeout: 5),
                      "Row ellipsis button should exist\n\(app.debugDescription)")
        let firstEllipsis = ellipsisButtons.firstMatch
        // Capture which track this ellipsis belongs to by checking which title is above it.
        // We'll just assert the navigated track title is present after Go-to-Source.
        firstEllipsis.tap()

        // The TrackContextSheet should appear with the Go-to-Source action.
        let goToSource = app.descendants(matching: .any)["goToSource"].firstMatch
        XCTAssertTrue(goToSource.waitForExistence(timeout: 5),
                      "Go to Source row should appear in the context sheet\n\(app.debugDescription)")
        goToSource.tap()

        // After tapping Go to Source:
        // - The sheet dismisses
        // - The tab flips to Library (RootView observes switchToLibraryToken)
        // - LibraryNav navigates to the folder holding the track
        // Give the UI time to settle (sheet dismiss + tab switch + nav update).
        let breadcrumb = app.descendants(matching: .any)["breadcrumb"].firstMatch
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 8),
                      "Breadcrumb should be visible after Go-to-Source navigates to the folder\n\(app.debugDescription)")

        // The navigated folder should contain at least one of the demo tracks.
        // (Go-to-Source landed on whichever track's folder — both live in the same root folder.)
        let biljamVisible = app.staticTexts["Biljam"].waitForExistence(timeout: 3)
        let mercyVisible = app.staticTexts["Mercy"].waitForExistence(timeout: 3)
        XCTAssertTrue(biljamVisible || mercyVisible,
                      "The navigated folder should contain the demo track(s)\n\(app.debugDescription)")
    }
}
