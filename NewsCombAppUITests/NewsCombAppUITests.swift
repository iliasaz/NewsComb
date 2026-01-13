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
    func testMainViewShowsRefreshButton() throws {
        let refreshButton = app.buttons["Refresh"]
        XCTAssertTrue(refreshButton.waitForExistence(timeout: 5), "Refresh button should exist")
    }

    @MainActor
    func testMainViewShowsEmptyStateWhenNoSources() throws {
        // Check for empty state message
        let emptyState = app.staticTexts["No RSS Sources"]
        XCTAssertTrue(emptyState.waitForExistence(timeout: 5), "Should show empty state when no sources")

        let description = app.staticTexts["Add RSS sources in Settings to get started."]
        XCTAssertTrue(description.exists, "Should show helpful description")
    }

    @MainActor
    func testAppLaunches() throws {
        // Basic test that app launches without crashing
        XCTAssertTrue(app.exists, "App should launch successfully")
    }

    @MainActor
    func testMainViewShowsAllArticlesSection() throws {
        // Check for All Articles navigation link
        let allArticles = app.staticTexts["All Articles"]
        XCTAssertTrue(allArticles.waitForExistence(timeout: 5), "Should show All Articles section")
    }
}
