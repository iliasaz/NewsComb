import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `list_parameter_presets` MCP tool, which returns a JSON
/// array describing every row in `parameter_preset` ordered with built-ins
/// first, then user presets alphabetically.
final class MCPListParameterPresetsToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPListPresetsTests-\(UUID().uuidString)")
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

    private func decode(_ json: String) throws -> [[String: Any]] {
        guard let data = json.data(using: .utf8) else {
            XCTFail("Tool returned non-UTF8 output")
            return []
        }
        guard let arr = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            XCTFail("Tool output was not a JSON array of objects: \(json)")
            return []
        }
        return arr
    }

    private func clearAllPresets() throws {
        try Database.current.write { db in
            try db.execute(sql: "DELETE FROM parameter_preset")
        }
    }

    // MARK: - Tests

    func testListsBothBuiltins() async throws {
        let result = try await MCPListParameterPresetsTool.run(arguments: [:])
        let arr = try decode(result)
        let names = arr.compactMap { $0["name"] as? String }
        XCTAssertTrue(names.contains(ParameterPreset.newsIntelligenceName))
        XCTAssertTrue(names.contains(ParameterPreset.codebaseIntelligenceName))

        for entry in arr {
            if let name = entry["name"] as? String,
               name == ParameterPreset.newsIntelligenceName ||
               name == ParameterPreset.codebaseIntelligenceName {
                let isBuiltin = entry["is_builtin"] as? Bool
                XCTAssertEqual(isBuiltin, true, "\(name) should be is_builtin=true")
                XCTAssertNotNil(entry["description"])
                XCTAssertNotNil(entry["updated_at"])
            }
        }
    }

    func testListsUserPresetsAlongsideBuiltins() async throws {
        // Insert a user preset.
        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT INTO parameter_preset (name, description, settings_json, is_builtin)
                    VALUES (?, ?, ?, 0)
                """,
                arguments: ["Aardvark Preset", "test", "{}"]
            )
        }

        let result = try await MCPListParameterPresetsTool.run(arguments: [:])
        let arr = try decode(result)
        let names = arr.compactMap { $0["name"] as? String }

        XCTAssertTrue(names.contains("Aardvark Preset"))

        // Order: built-ins first (is_builtin=1), then user presets.
        // "Aardvark Preset" — even though it sorts alphabetically before
        // both built-ins — must come AFTER both because is_builtin DESC.
        let aardvarkIdx = names.firstIndex(of: "Aardvark Preset") ?? -1
        let newsIdx = names.firstIndex(of: ParameterPreset.newsIntelligenceName) ?? -1
        let codebaseIdx = names.firstIndex(of: ParameterPreset.codebaseIntelligenceName) ?? -1
        XCTAssertGreaterThan(aardvarkIdx, newsIdx)
        XCTAssertGreaterThan(aardvarkIdx, codebaseIdx)
    }

    func testEmptyDatabaseReturnsEmptyArray() async throws {
        try clearAllPresets()
        let result = try await MCPListParameterPresetsTool.run(arguments: [:])
        let arr = try decode(result)
        XCTAssertEqual(arr.count, 0)
    }
}
