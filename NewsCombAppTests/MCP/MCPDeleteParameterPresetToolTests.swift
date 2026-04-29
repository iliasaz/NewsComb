import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `delete_parameter_preset` MCP tool, which removes a
/// user-defined preset row. Built-in presets are protected.
final class MCPDeleteParameterPresetToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPDeletePresetTests-\(UUID().uuidString)")
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

    private func count(name: String) throws -> Int {
        try Database.current.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM parameter_preset WHERE name = ?",
                arguments: [name]
            ) ?? 0
        }
    }

    private func writeUserPreset(name: String) throws {
        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO parameter_preset (name, description, settings_json, is_builtin)
                    VALUES (?, ?, ?, 0)
                """,
                arguments: [name, "test", "{}"]
            )
        }
    }

    // MARK: - Tests

    func testDeleteUserPreset() async throws {
        try writeUserPreset(name: "To Delete")

        let result = try await MCPDeleteParameterPresetTool.run(
            arguments: ["name": .string("To Delete")]
        )
        XCTAssertTrue(result.localizedStandardContains("deleted"))
        XCTAssertEqual(try count(name: "To Delete"), 0)
    }

    func testRefuseDeletingBuiltin() async throws {
        do {
            _ = try await MCPDeleteParameterPresetTool.run(
                arguments: ["name": .string(ParameterPreset.newsIntelligenceName)]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains("reset_parameter_preset"),
                "Error should reference reset_parameter_preset; was: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }

        // Built-in must still exist.
        XCTAssertEqual(try count(name: ParameterPreset.newsIntelligenceName), 1)
    }

    func testNotFoundForMissingPreset() async {
        do {
            _ = try await MCPDeleteParameterPresetTool.run(
                arguments: ["name": .string("Nonexistent")]
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
