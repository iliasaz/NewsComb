import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `update_parameter_preset` MCP tool, which mutates an
/// existing preset row by merging supplied fields into it.
final class MCPUpdateParameterPresetToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPUpdatePresetTests-\(UUID().uuidString)")
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

    private func fetchRow(name: String) throws -> ParameterPreset? {
        try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
    }

    private func decodeSettings(_ row: ParameterPreset) throws -> [String: String] {
        let data = try XCTUnwrap(row.settingsJSON.data(using: .utf8))
        return try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
    }

    private func writeUserPreset(name: String, description: String, settings: [String: String]) throws {
        let data = try JSONSerialization.data(withJSONObject: settings, options: [.sortedKeys])
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO parameter_preset (name, description, settings_json, is_builtin, created_at, updated_at)
                    VALUES (?, ?, ?, 0, 1000, 1000)
                """,
                arguments: [name, description, json]
            )
        }
    }

    // MARK: - Tests

    func testPartialUpdatePreservesOmittedFields() async throws {
        try writeUserPreset(
            name: "Partial",
            description: "original desc",
            settings: [AppSettings.chunkSize: "800"]
        )

        _ = try await MCPUpdateParameterPresetTool.run(
            arguments: [
                "name": .string("Partial"),
                "description": .string("new desc")
            ]
        )

        let row = try XCTUnwrap(try fetchRow(name: "Partial"))
        XCTAssertEqual(row.description, "new desc")
        let settings = try decodeSettings(row)
        XCTAssertEqual(settings[AppSettings.chunkSize], "800")
    }

    func testSettingsUpdateMergesNotReplaces() async throws {
        try writeUserPreset(
            name: "Merge",
            description: "to merge",
            settings: [
                AppSettings.chunkSize: "800",
                AppSettings.umapTargetDimension: "25"
            ]
        )

        _ = try await MCPUpdateParameterPresetTool.run(
            arguments: [
                "name": .string("Merge"),
                "settings": .object([
                    AppSettings.umapTargetDimension: .string("30"),
                    AppSettings.hdbscanMinSamples: .string("7")
                ])
            ]
        )

        let row = try XCTUnwrap(try fetchRow(name: "Merge"))
        let settings = try decodeSettings(row)
        XCTAssertEqual(settings[AppSettings.chunkSize], "800")            // preserved
        XCTAssertEqual(settings[AppSettings.umapTargetDimension], "30")   // updated
        XCTAssertEqual(settings[AppSettings.hdbscanMinSamples], "7")      // added
    }

    func testValidationOnUpdate() async throws {
        try writeUserPreset(
            name: "Bad Update",
            description: "test",
            settings: [AppSettings.chunkSize: "800"]
        )

        do {
            _ = try await MCPUpdateParameterPresetTool.run(
                arguments: [
                    "name": .string("Bad Update"),
                    "settings": .object([
                        AppSettings.umapTargetDimension: .string("9999")
                    ])
                ]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains(AppSettings.umapTargetDimension),
                "Got: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }
    }

    func testUpdatedAtChanges() async throws {
        try writeUserPreset(
            name: "Stamps",
            description: "test",
            settings: [AppSettings.chunkSize: "800"]
        )

        let before = try XCTUnwrap(try fetchRow(name: "Stamps"))

        _ = try await MCPUpdateParameterPresetTool.run(
            arguments: [
                "name": .string("Stamps"),
                "description": .string("new")
            ]
        )

        let after = try XCTUnwrap(try fetchRow(name: "Stamps"))
        XCTAssertGreaterThan(after.updatedAt, before.updatedAt)
    }

    func testNotFoundForMissingPreset() async {
        do {
            _ = try await MCPUpdateParameterPresetTool.run(
                arguments: [
                    "name": .string("Nonexistent Update Target"),
                    "description": .string("x")
                ]
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

    func testCanUpdateBuiltin() async throws {
        // News Intelligence is seeded as a built-in.
        _ = try await MCPUpdateParameterPresetTool.run(
            arguments: [
                "name": .string(ParameterPreset.newsIntelligenceName),
                "description": .string("custom built-in description")
            ]
        )

        let row = try XCTUnwrap(try fetchRow(name: ParameterPreset.newsIntelligenceName))
        XCTAssertEqual(row.description, "custom built-in description")
        XCTAssertTrue(row.isBuiltin)
    }
}
