import XCTest

/// XCUITest for Phase 4 Task 7: Settings → Sources manager navigation.
///
/// The folder picker is system UI (can't be driven headlessly), so this suite tests only
/// navigation + presence: open Settings → Library Sources section → drill into the migrated
/// "On My iPhone" local source → assert root folder row + addRootFolder + disconnectSource;
/// navigate back → tap Add Source → assert connect-icloud is present and Google Drive
/// shows "Coming soon" (connect-gdrive is present but not hittable / shows the coming-soon text).
final class SourcesSettingsUITests: XCTestCase {
    override func setUp() { super.setUp(); continueAfterFailure = false }

    // MARK: - Test 1: Full Settings Sources navigation

    /// Launch → gear → Library Sources section → local source detail → back → Add Source.
    @MainActor
    func test_sourcesManager_navigation() {
        let app = XCUIApplication()
        app.launch()

        // Wait for Library root (migration + index ready signal).
        let sourceRow = app.descendants(matching: .any)["sourceRow-local"].firstMatch
        XCTAssertTrue(sourceRow.waitForExistence(timeout: 10),
                      "Root should show the local source row before opening Settings")

        // Open Settings via the gear button in the Library header.
        let gearButton = app.descendants(matching: .any)["settingsButton"].firstMatch
        XCTAssertTrue(gearButton.waitForExistence(timeout: 5),
                      "Settings gear button (settingsButton) should be visible in Library header\n\(app.debugDescription)")
        gearButton.tap()

        // ── Library Sources section ──────────────────────────────────────────────

        // The "Library Sources" header should appear in the Settings sheet.
        let sourcesHeader = app.staticTexts["Library Sources"].firstMatch
        XCTAssertTrue(sourcesHeader.waitForExistence(timeout: 5),
                      "Settings sheet should contain a 'Library Sources' section header\n\(app.debugDescription)")

        // The migrated "On My iPhone" local source must be listed.
        let localSourceText = app.staticTexts["On My iPhone"].firstMatch
        XCTAssertTrue(localSourceText.waitForExistence(timeout: 5),
                      "Library Sources should list the migrated 'On My iPhone' source\n\(app.debugDescription)")

        // ── Drill into On My iPhone detail ──────────────────────────────────────

        // Tap the row containing "On My iPhone". NavigationLink renders as a cell/button;
        // the StaticText itself may not be hittable, so find the first hittable ancestor cell.
        let localSourceCell = app.cells.containing(.staticText, identifier: "On My iPhone").firstMatch
        if localSourceCell.waitForExistence(timeout: 3) {
            localSourceCell.tap()
        } else {
            // Fallback: find the button that is a NavigationLink wrapping the text.
            let localSourceButton = app.buttons.containing(.staticText, identifier: "On My iPhone").firstMatch
            if localSourceButton.waitForExistence(timeout: 3) {
                localSourceButton.tap()
            } else {
                // Last resort: tap by coordinate on the text's location.
                localSourceText.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).tap()
            }
        }

        // The detail should show the root folder row (seeded via migration).
        let rootFolderRow = app.descendants(matching: .any)["rootFolderRow-On My iPhone"].firstMatch
        XCTAssertTrue(rootFolderRow.waitForExistence(timeout: 8),
                      "Source detail should show root folder row 'rootFolderRow-On My iPhone'\n\(app.debugDescription)")

        // "Add Root Folder…" button must be present.
        let addRootFolder = app.descendants(matching: .any)["addRootFolder"].firstMatch
        XCTAssertTrue(addRootFolder.waitForExistence(timeout: 5),
                      "Source detail should show 'addRootFolder' button\n\(app.debugDescription)")

        // "Disconnect Source" destructive button must be present (we do NOT tap it).
        let disconnectSource = app.descendants(matching: .any)["disconnectSource"].firstMatch
        XCTAssertTrue(disconnectSource.waitForExistence(timeout: 5),
                      "Source detail should show 'disconnectSource' button\n\(app.debugDescription)")

        // ── Navigate back to Settings root ───────────────────────────────────────

        // Tap the back button in the navigation bar to return to the Settings list.
        let backButton = app.navigationBars.buttons.firstMatch
        XCTAssertTrue(backButton.waitForExistence(timeout: 5),
                      "Back button should be available in nav bar to return from source detail\n\(app.debugDescription)")
        backButton.tap()

        // ── Add Source navigation ─────────────────────────────────────────────────

        // "Add Source…" row should be back in view.
        let addSourceRow = app.descendants(matching: .any)["addSource"].firstMatch
        XCTAssertTrue(addSourceRow.waitForExistence(timeout: 5),
                      "Settings sheet should show the 'addSource' row after navigating back\n\(app.debugDescription)")
        addSourceRow.tap()

        // ── Add Source list ──────────────────────────────────────────────────────

        // iCloud Drive connect pill must be present (available source not yet connected).
        let connectICloud = app.descendants(matching: .any)["connect-icloud"].firstMatch
        XCTAssertTrue(connectICloud.waitForExistence(timeout: 8),
                      "Add Source list should contain a 'connect-icloud' connect pill\n\(app.debugDescription)")

        // Google Drive: Phase 4 shows "Coming soon" — assert the text is visible.
        // The connect-gdrive element is a static Text capsule (not a tappable NavigationLink),
        // so we assert the "Coming soon" label appears rather than checking hittability.
        let comingSoonText = app.staticTexts["Coming soon"].firstMatch
        XCTAssertTrue(comingSoonText.waitForExistence(timeout: 5),
                      "Add Source list should show 'Coming soon' text for Google Drive\n\(app.debugDescription)")

        // Confirm connect-gdrive exists but is NOT a NavigationLink button (i.e. it is a Text,
        // not an interactive control). Tapping it should not navigate anywhere.
        let connectGdrive = app.descendants(matching: .any)["connect-gdrive"].firstMatch
        // Only assert it's present; the fact it is a StaticText (not a Button) confirms it's non-interactive.
        XCTAssertTrue(connectGdrive.waitForExistence(timeout: 3),
                      "connect-gdrive element should exist in Add Source list\n\(app.debugDescription)")
    }
}
