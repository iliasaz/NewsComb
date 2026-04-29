import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `get_settings` MCP tool, which reads `app_settings` rows
/// grouped by `SettingsCategory` and redacts secret keys by default.
///
/// Uses `Database.setCurrent(_:)` as a test seam: each test points the
/// app at a temp-directory `Database` so writes happen there, then resets
/// in tearDown. The tool itself reads `Database.current` directly.
final class MCPGetSettingsToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPGetSettingsTests-\(UUID().uuidString)")
        let database = try Database(directory: tempRoot)
        Database.setCurrent(database)
    }

    override func tearDown() async throws {
        Database.resetCurrentForTesting()
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    /// Decodes the tool's JSON output into a `[category: [key: value]]` dictionary.
    private func decode(_ json: String) throws -> [String: [String: String]] {
        guard let data = json.data(using: .utf8) else {
            XCTFail("Tool returned non-UTF8 output")
            return [:]
        }
        let decoded = try JSONDecoder().decode([String: [String: String]].self, from: data)
        return decoded
    }

    // MARK: - Tests

    func testReturnsAllCategoriesByDefault() async throws {
        let result = try await MCPGetSettingsTool.run(arguments: [:])
        let dict = try decode(result)
        // Phase 1A defines 7 categories.
        let expected: Set<String> = [
            "extraction", "clustering", "rag", "analysis",
            "llm", "feeds", "simulation"
        ]
        XCTAssertEqual(Set(dict.keys), expected)
    }

    func testReturnsSingleCategory() async throws {
        let result = try await MCPGetSettingsTool.run(
            arguments: ["category": .string("feeds")]
        )
        let dict = try decode(result)
        XCTAssertEqual(Array(dict.keys), ["feeds"])
        // The feeds category seeds article_age_limit_days with the default value.
        let feeds = try XCTUnwrap(dict["feeds"])
        XCTAssertEqual(
            feeds[AppSettings.articleAgeLimitDays],
            String(AppSettings.defaultArticleAgeLimitDays)
        )
    }

    func testRedactsSecretsByDefault() async throws {
        // Populate the secret first.
        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [AppSettings.openRouterKey, "sk-secret-token-123"]
            )
        }
        let result = try await MCPGetSettingsTool.run(
            arguments: ["category": .string("llm")]
        )
        XCTAssertFalse(result.contains("sk-secret-token-123"))
        XCTAssertTrue(result.contains("<redacted>"))

        let dict = try decode(result)
        let llm = try XCTUnwrap(dict["llm"])
        XCTAssertEqual(llm[AppSettings.openRouterKey], "<redacted>")
    }

    func testIncludeSecretsTrueRevealsKey() async throws {
        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [AppSettings.openRouterKey, "sk-secret-token-456"]
            )
        }
        let result = try await MCPGetSettingsTool.run(
            arguments: [
                "category": .string("llm"),
                "include_secrets": .bool(true)
            ]
        )
        let dict = try decode(result)
        let llm = try XCTUnwrap(dict["llm"])
        XCTAssertEqual(llm[AppSettings.openRouterKey], "sk-secret-token-456")
    }

    func testUnknownCategoryThrowsInvalidParameter() async {
        do {
            _ = try await MCPGetSettingsTool.run(
                arguments: ["category": .string("nonexistent_xyz")]
            )
            XCTFail("Should have thrown an MCPToolError")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.localizedStandardContains("category"),
                "Error should reference 'category'; was: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }
    }

    func testMissingValueReturnsEmptyString() async throws {
        // The simulation category currently lists no keys; pick a category whose
        // keys include an unseeded one. `articleAgeLimitDays` is seeded by default,
        // so we delete it to ensure missing values surface as "".
        try Database.current.write { db in
            try db.execute(
                sql: "DELETE FROM app_settings WHERE key = ?",
                arguments: [AppSettings.articleAgeLimitDays]
            )
        }
        let result = try await MCPGetSettingsTool.run(
            arguments: ["category": .string("feeds")]
        )
        let dict = try decode(result)
        let feeds = try XCTUnwrap(dict["feeds"])
        // Key should be present in output even when the row is missing,
        // with an empty string value.
        XCTAssertEqual(feeds[AppSettings.articleAgeLimitDays], "")
    }
}
