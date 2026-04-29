import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `create_parameter_preset` MCP tool, which writes a new
/// user-defined preset row after validating every setting.
final class MCPCreateParameterPresetToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPCreatePresetTests-\(UUID().uuidString)")
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

    private func fetchPresetRow(name: String) throws -> ParameterPreset? {
        try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
    }

    // MARK: - Tests

    func testHappyPathCreatesUserPreset() async throws {
        let result = try await MCPCreateParameterPresetTool.run(
            arguments: [
                "name": .string("My Custom Preset"),
                "description": .string("My custom description"),
                "settings": .object([
                    AppSettings.chunkSize: .string("1000"),
                    AppSettings.umapTargetDimension: .string("20")
                ])
            ]
        )
        XCTAssertTrue(result.localizedStandardContains("created"))

        let row = try XCTUnwrap(try fetchPresetRow(name: "My Custom Preset"))
        XCTAssertFalse(row.isBuiltin)
        XCTAssertEqual(row.description, "My custom description")

        let data = try XCTUnwrap(row.settingsJSON.data(using: .utf8))
        let parsed = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: String]
        )
        XCTAssertEqual(parsed[AppSettings.chunkSize], "1000")
        XCTAssertEqual(parsed[AppSettings.umapTargetDimension], "20")
    }

    func testDuplicateNameRejected() async throws {
        // First create succeeds.
        _ = try await MCPCreateParameterPresetTool.run(
            arguments: [
                "name": .string("Dup Preset"),
                "description": .string("first"),
                "settings": .object([
                    AppSettings.chunkSize: .string("500")
                ])
            ]
        )

        // Second create with the same name must fail.
        do {
            _ = try await MCPCreateParameterPresetTool.run(
                arguments: [
                    "name": .string("Dup Preset"),
                    "description": .string("second"),
                    "settings": .object([
                        AppSettings.chunkSize: .string("700")
                    ])
                ]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.localizedStandardContains("Dup Preset") ||
                    error.message.localizedStandardContains("already"),
                "Got: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }
    }

    func testInvalidValueRejected() async {
        do {
            _ = try await MCPCreateParameterPresetTool.run(
                arguments: [
                    "name": .string("Bad Values Preset"),
                    "description": .string("test"),
                    "settings": .object([
                        AppSettings.umapTargetDimension: .string("bogus")
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

    func testUnknownKeyRejected() async {
        do {
            _ = try await MCPCreateParameterPresetTool.run(
                arguments: [
                    "name": .string("Unknown Key Preset"),
                    "description": .string("test"),
                    "settings": .object([
                        "totally_not_a_real_key": .string("123")
                    ])
                ]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains("totally_not_a_real_key"),
                "Got: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }
    }
}
