import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `reset_parameter_preset` MCP tool, which restores
/// built-in presets to their seeded defaults and is a no-op for
/// user-defined presets.
final class MCPResetParameterPresetToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPResetPresetTests-\(UUID().uuidString)")
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

    private func fetchRow(name: String) throws -> ParameterPreset? {
        try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
    }

    // MARK: - Tests

    func testResetBuiltinAfterEdit() async throws {
        // Mutate description.
        _ = try await MCPUpdateParameterPresetTool.run(
            arguments: [
                "name": .string(ParameterPreset.newsIntelligenceName),
                "description": .string("custom description")
            ]
        )

        // Now reset.
        let result = try await MCPResetParameterPresetTool.run(
            arguments: ["name": .string(ParameterPreset.newsIntelligenceName)]
        )
        XCTAssertTrue(result.localizedStandardContains("reset"))

        let row = try XCTUnwrap(try fetchRow(name: ParameterPreset.newsIntelligenceName))
        XCTAssertEqual(row.description, ParameterPreset.newsIntelligenceDescription)

        // Settings should match seeded defaults.
        let data = try XCTUnwrap(row.settingsJSON.data(using: .utf8))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(parsed[AppSettings.chunkSize], "800")
    }

    func testResetUserPresetIsNoop() async throws {
        // Insert a user preset.
        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO parameter_preset (name, description, settings_json, is_builtin)
                    VALUES (?, ?, ?, 0)
                """,
                arguments: ["User Preset", "user-defined", "{\"chunk_size\":\"500\"}"]
            )
        }

        let before = try XCTUnwrap(try fetchRow(name: "User Preset"))

        let result = try await MCPResetParameterPresetTool.run(
            arguments: ["name": .string("User Preset")]
        )
        XCTAssertTrue(result.localizedStandardContains("user-defined"))

        let after = try XCTUnwrap(try fetchRow(name: "User Preset"))
        XCTAssertEqual(after.description, before.description)
        XCTAssertEqual(after.settingsJSON, before.settingsJSON)
    }

    func testNotFoundForMissingPreset() async {
        do {
            _ = try await MCPResetParameterPresetTool.run(
                arguments: ["name": .string("Definitely Does Not Exist")]
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
}
