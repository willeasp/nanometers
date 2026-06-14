import XCTest

/// Headless end-to-end UI test for the Google Drive source pipeline:
/// connect → browse folders → scoped search → Go-to-Source.
/// Uses `-mock-drive` to plant a Google Drive source with a fixed 2-level tree
/// (MockSourceProvider) so no OAuth / network is required.
///
/// Navigation hierarchy after `-mock-drive`:
///   Library root
///   └── Google Drive (sourceRow-gdrive)
///       └── Mock Drive (folderRow-Mock Drive)   ← the single RootFolder
///           ├── House (folderRow-House)
///           │   ├── Mock Caldera
///           │   └── Mock Strata
///           └── DnB (folderRow-DnB)
///               └── Mock Abyss
///
/// Teardown: re-launches the app with `-clear-cloud-sources` to remove the gdrive source so
/// subsequent tests (including test_normalLaunch_hasNoGdriveRow) see a clean state.
final class DriveMockFlowUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    override func tearDown() {
        // Remove the mock gdrive source so normal-launch tests start clean.
        let app = XCUIApplication()
        app.launchArguments = ["-clear-cloud-sources"]
        app.launch()
        // Wait a moment for the clear to commit, then terminate.
        _ = app.staticTexts["All Songs"].waitForExistence(timeout: 8)
        app.terminate()
        super.tearDown()
    }

    // MARK: - Test 1: Full Drive flow

    @MainActor
    func test_mockDrive_fullFlow_connectBrowseSearchGoToSource() {
        let app = XCUIApplication()
        app.launchArguments = ["-mock-drive"]
        app.launch()

        // MARK: 1 — Library root shows the Google Drive source row

        let driveRow = app.descendants(matching: .any)["sourceRow-gdrive"].firstMatch
        XCTAssertTrue(driveRow.waitForExistence(timeout: 12),
                      "Library root must show the Google Drive source row (sourceRow-gdrive)\n\(app.debugDescription)")
        driveRow.tap()

        // MARK: 2 — Source level shows the "Mock Drive" root folder

        // At source root level we see the RootFolder entry for "Mock Drive".
        let mockDriveRow = app.descendants(matching: .any)["folderRow-Mock Drive"].firstMatch
        XCTAssertTrue(mockDriveRow.waitForExistence(timeout: 8),
                      "Source level should show 'Mock Drive' root folder row\n\(app.debugDescription)")
        mockDriveRow.tap()

        // MARK: 3 — Inside Mock Drive: "House" and "DnB" child folders

        let houseRow = app.descendants(matching: .any)["folderRow-House"].firstMatch
        XCTAssertTrue(houseRow.waitForExistence(timeout: 8),
                      "Mock Drive should contain 'House' folder row\n\(app.debugDescription)")

        let dnbRow = app.descendants(matching: .any)["folderRow-DnB"].firstMatch
        XCTAssertTrue(dnbRow.waitForExistence(timeout: 5),
                      "Mock Drive should contain 'DnB' folder row\n\(app.debugDescription)")

        // MARK: 4 — Drill into House → see mock tracks

        houseRow.tap()

        XCTAssertTrue(app.staticTexts["Mock Caldera"].waitForExistence(timeout: 8),
                      "House folder should contain 'Mock Caldera'\n\(app.debugDescription)")
        XCTAssertTrue(app.staticTexts["Mock Strata"].waitForExistence(timeout: 5),
                      "House folder should contain 'Mock Strata'\n\(app.debugDescription)")

        // MARK: 5 — Scoped search within House filters to one track

        let searchToggle = app.buttons["searchToggle"].firstMatch
        XCTAssertTrue(searchToggle.waitForExistence(timeout: 5),
                      "Search toggle should be visible at folder level\n\(app.debugDescription)")
        searchToggle.tap()

        let searchField = app.textFields["scopedSearchField"].firstMatch
        XCTAssertTrue(searchField.waitForExistence(timeout: 5),
                      "Scoped search field should appear after tapping searchToggle\n\(app.debugDescription)")
        searchField.tap()
        searchField.typeText("Caldera")

        XCTAssertTrue(app.staticTexts["Mock Caldera"].waitForExistence(timeout: 5),
                      "Search results should show 'Mock Caldera'\n\(app.debugDescription)")
        XCTAssertFalse(app.staticTexts["Mock Strata"].waitForExistence(timeout: 2),
                       "Search results should NOT show 'Mock Strata' when querying 'Caldera'")

        // MARK: 6 — Open the track's ⋯ → Go-to-Source navigates (breadcrumb appears)

        let ellipsis = app.buttons["rowEllipsis"].firstMatch
        XCTAssertTrue(ellipsis.waitForExistence(timeout: 5),
                      "Row ellipsis button should be visible\n\(app.debugDescription)")
        ellipsis.tap()

        let goToSource = app.descendants(matching: .any)["goToSource"].firstMatch
        XCTAssertTrue(goToSource.waitForExistence(timeout: 5),
                      "Go to Source row should appear in the context sheet\n\(app.debugDescription)")
        goToSource.tap()

        // After Go-to-Source the Library navigates to the folder holding the track.
        // The breadcrumb element confirms we landed in a folder view.
        let breadcrumb = app.descendants(matching: .any)["breadcrumb"].firstMatch
        XCTAssertTrue(breadcrumb.waitForExistence(timeout: 8),
                      "Breadcrumb should be visible after Go-to-Source navigates to the folder\n\(app.debugDescription)")

        // The navigated folder should contain Mock Caldera (our Go-to-Source target).
        XCTAssertTrue(app.staticTexts["Mock Caldera"].waitForExistence(timeout: 5),
                      "The navigated folder should contain 'Mock Caldera'\n\(app.debugDescription)")
    }

    // MARK: - Test 2: Normal launch (no -mock-drive) has no Google Drive row

    /// Verify that a normal launch (no `-mock-drive`) does NOT show a Google Drive source row.
    /// Relies on `tearDown` having cleared the gdrive source from the previous test.
    @MainActor
    func test_normalLaunch_hasNoGdriveRow() {
        let app = XCUIApplication()
        // No -mock-drive argument — standard launch.
        app.launch()

        // Wait for Library root to be ready (local source appears).
        let localRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(localRow.waitForExistence(timeout: 12),
                      "Root should show the local source row on a normal launch")

        // Google Drive row must NOT be present.
        XCTAssertFalse(app.descendants(matching: .any)["sourceRow-gdrive"].firstMatch.waitForExistence(timeout: 3),
                       "Normal launch must NOT show a Google Drive source row")
    }
}
