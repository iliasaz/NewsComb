import XCTest

final class NewsCombAppUITests: XCTestCase {
    @MainActor
    var app: XCUIApplication!

    @MainActor
    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
    }

    @MainActor
    override func tearDown() async throws {
        app = nil
        try await super.tearDown()
    }

    // MARK: - Main View Tests

    @MainActor
    func testAppLaunches() throws {
        // Basic test that app launches without crashing
        XCTAssertTrue(app.exists, "App should launch successfully")
    }

    @MainActor
    func testMainViewShowsRefreshButton() throws {
        let refreshButton = app.buttons["Refresh"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 5), "Refresh button should exist")
    }

    // MARK: - Export Feature Tests

    @MainActor
    func testMainViewShowsExportAllButton() throws {
        // Export All button should exist in the toolbar
        let exportButton = app.buttons["Export All"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 5), "Export All button should exist")
    }

    @MainActor
    func testMainViewShowsClearAllButton() throws {
        // Clear All button should exist in the toolbar
        let clearButton = app.buttons["Clear All"]
        XCTAssertTrue(clearButton.waitForExistence(timeout: 5), "Clear All button should exist")
    }

    @MainActor
    func testExportAllButtonExists() throws {
        // Export All button should exist
        let exportButton = app.buttons["Export All"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 5), "Export All button should exist in toolbar")
    }

    @MainActor
    func testToolbarButtonsExist() throws {
        // All toolbar buttons should exist
        XCTAssertTrue(app.buttons["Refresh"].waitForExistence(timeout: 5), "Refresh button should exist")
        XCTAssertTrue(app.buttons["Export All"].exists, "Export All button should exist")
        XCTAssertTrue(app.buttons["Clear All"].exists, "Clear All button should exist")
    }

    @MainActor
    func testRefreshButtonExists() throws {
        let refreshButton = app.buttons["Refresh"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 5), "Refresh button should exist")
        // Note: Refresh button may be disabled when there are no sources
    }
}
