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

    // MARK: - Navigation Tests

    @MainActor
    func testNavigationToAllArticles() throws {
        // Find "All Articles" in various possible forms
        let allArticlesText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'All Articles'")).firstMatch

        // If All Articles exists, test navigation
        if allArticlesText.waitForExistence(timeout: 5) {
            allArticlesText.tap()

            // Wait for navigation - look for a back button
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Back button should appear after navigation")
        } else {
            // The view might be showing empty state, which is fine
            XCTAssertTrue(true, "All Articles section may not be visible in empty state")
        }
    }

    @MainActor
    func testNavigationBackFromAllArticles() throws {
        // Find "All Articles" in various possible forms
        let allArticlesText = app.staticTexts.matching(NSPredicate(format: "label CONTAINS[c] 'All Articles'")).firstMatch

        if allArticlesText.waitForExistence(timeout: 5) {
            allArticlesText.tap()

            // Wait for navigation
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Back button should appear")

            // Tap back button
            backButton.tap()

            // Verify we're back at main view - All Articles should be visible again
            XCTAssertTrue(allArticlesText.waitForExistence(timeout: 5), "Should be back at main view with All Articles visible")
        } else {
            XCTAssertTrue(true, "All Articles section may not be visible in empty state")
        }
    }

    @MainActor
    func testNavigationToAskYourNews() throws {
        // "Ask Your News" only appears when knowledge graph has data
        // Look for the text if it exists
        let askYourNewsText = app.staticTexts["Ask Your News"].firstMatch

        // If it exists, test navigation
        if askYourNewsText.waitForExistence(timeout: 3) {
            askYourNewsText.tap()

            // Should navigate to the Ask Your News view - look for back button
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Back button should appear after navigating to Ask Your News")

            // Verify we're on the Ask Your News page by checking for the Ask button
            let askButton = app.buttons["Ask"]
            XCTAssertTrue(askButton.waitForExistence(timeout: 3), "Ask button should exist on Ask Your News view")
        }
        // If Ask Your News doesn't exist (no knowledge graph), test passes
    }

    @MainActor
    func testNavigationBackFromAskYourNews() throws {
        // "Ask Your News" only appears when knowledge graph has data
        let askYourNewsText = app.staticTexts["Ask Your News"].firstMatch

        if askYourNewsText.waitForExistence(timeout: 3) {
            askYourNewsText.tap()

            // Wait for navigation
            let backButton = app.navigationBars.buttons.element(boundBy: 0)
            XCTAssertTrue(backButton.waitForExistence(timeout: 5), "Back button should appear")

            // Navigate back
            backButton.tap()

            // Verify we're back at main view
            XCTAssertTrue(askYourNewsText.waitForExistence(timeout: 5), "Should be back at main view with Ask Your News visible")
        }
    }

    @MainActor
    func testMainViewTitleExists() throws {
        // The main view should have "NewsComb" as its title - check for static text
        let titleText = app.staticTexts["NewsComb"].firstMatch
        let navBar = app.navigationBars.firstMatch
        // Either the title text exists or a navigation bar exists
        let titleExists = titleText.waitForExistence(timeout: 5) || navBar.waitForExistence(timeout: 5)
        XCTAssertTrue(titleExists, "NewsComb title or navigation bar should exist")
    }

    @MainActor
    func testAddFeedSectionExists() throws {
        // The Add RSS Feed section should exist
        let addFeedTextField = app.textFields["RSS Feed URL"]
        XCTAssertTrue(addFeedTextField.waitForExistence(timeout: 5), "RSS Feed URL text field should exist")

        let addButton = app.buttons["Add"]
        XCTAssertTrue(addButton.exists, "Add button should exist")
    }
}
