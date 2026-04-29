import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `get_parameter_preset` MCP tool, which returns the full
/// preset row with parsed settings JSON. Secret keys are redacted by
/// default; pass `include_secrets=true` to reveal them.
final class MCPGetParameterPresetToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPGetPresetTests-\(UUID().uuidString)")
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

    private func decode(_ json: String) throws -> [String: Any] {
        guard let data = json.data(using: .utf8) else {
            XCTFail("Tool returned non-UTF8 output")
            return [:]
        }
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("Tool output was not a JSON object: \(json)")
            return [:]
        }
        return dict
    }

    // MARK: - Tests

    func testFetchBuiltinPreset() async throws {
        let result = try await MCPGetParameterPresetTool.run(
            arguments: ["name": .string(ParameterPreset.newsIntelligenceName)]
        )
        let dict = try decode(result)
        XCTAssertEqual(dict["name"] as? String, ParameterPreset.newsIntelligenceName)
        XCTAssertEqual(dict["is_builtin"] as? Bool, true)

        let settings = try XCTUnwrap(dict["settings"] as? [String: String])
        XCTAssertEqual(settings[AppSettings.chunkSize], "800")
    }

    func testNotFoundForMissingName() async {
        do {
            _ = try await MCPGetParameterPresetTool.run(
                arguments: ["name": .string("Nonexistent Preset XYZ")]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.localizedStandardContains("not found"),
                "Got: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }
    }

    func testRedactsSecretsByDefault() async throws {
        // Create a user preset that includes the openrouter_key value.
        let settingsDict: [String: String] = [
            AppSettings.openRouterKey: "sk-very-secret-token",
            AppSettings.chunkSize: "800"
        ]
        let data = try JSONSerialization.data(
            withJSONObject: settingsDict,
            options: [.sortedKeys]
        )
        let json = String(data: data, encoding: .utf8) ?? "{}"

        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO parameter_preset (name, description, settings_json, is_builtin)
                    VALUES (?, ?, ?, 0)
                """,
                arguments: ["Secret Preset", "has a key", json]
            )
        }

        let result = try await MCPGetParameterPresetTool.run(
            arguments: ["name": .string("Secret Preset")]
        )
        XCTAssertFalse(result.contains("sk-very-secret-token"))
        XCTAssertTrue(result.contains("<redacted>"))

        let dict = try decode(result)
        let settings = try XCTUnwrap(dict["settings"] as? [String: String])
        XCTAssertEqual(settings[AppSettings.openRouterKey], "<redacted>")
        XCTAssertEqual(settings[AppSettings.chunkSize], "800")
    }

    func testIncludeSecretsTrueRevealsKey() async throws {
        let settingsDict: [String: String] = [
            AppSettings.openRouterKey: "sk-cleartext-456"
        ]
        let data = try JSONSerialization.data(
            withJSONObject: settingsDict,
            options: [.sortedKeys]
        )
        let json = String(data: data, encoding: .utf8) ?? "{}"

        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO parameter_preset (name, description, settings_json, is_builtin)
                    VALUES (?, ?, ?, 0)
                """,
                arguments: ["Cleartext Preset", "raw", json]
            )
        }

        let result = try await MCPGetParameterPresetTool.run(
            arguments: [
                "name": .string("Cleartext Preset"),
                "include_secrets": .bool(true)
            ]
        )
        let dict = try decode(result)
        let settings = try XCTUnwrap(dict["settings"] as? [String: String])
        XCTAssertEqual(settings[AppSettings.openRouterKey], "sk-cleartext-456")
    }
}
