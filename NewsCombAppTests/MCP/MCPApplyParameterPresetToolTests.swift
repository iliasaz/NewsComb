import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `apply_parameter_preset` MCP tool, which writes every
/// `app_settings` value referenced by a preset after validating all values
/// atomically.
final class MCPApplyParameterPresetToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPApplyPresetTests-\(UUID().uuidString)")
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

    private func readValue(_ key: String) throws -> String? {
        try Database.current.read { db in
            try AppSettings
                .filter(AppSettings.Columns.key == key)
                .fetchOne(db)?
                .value
        }
    }

    private func writePreset(name: String, settings: [String: String], isBuiltin: Bool = false) throws {
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys]
        )
        let json = String(data: data, encoding: .utf8) ?? "{}"
        try Database.current.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO parameter_preset (name, description, settings_json, is_builtin)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [name, "test preset", json, isBuiltin ? 1 : 0]
            )
        }
    }

    // MARK: - Tests

    func testApplyCodebaseIntelligenceFlipsAllKeys() async throws {
        let result = try await MCPApplyParameterPresetTool.run(
            arguments: ["name": .string(ParameterPreset.codebaseIntelligenceName)]
        )
        XCTAssertTrue(result.localizedStandardContains("applied"))

        XCTAssertEqual(try readValue(AppSettings.chunkSize), "1200")
        XCTAssertEqual(try readValue(AppSettings.umapTargetDimension), "15")
        XCTAssertEqual(try readValue(AppSettings.distillationEnabled), "true")

        let extractionPrompt = try readValue(AppSettings.extractionSystemPrompt) ?? ""
        XCTAssertTrue(extractionPrompt.contains("knowledge graph extractor"))
    }

    func testNotFoundForMissingPreset() async {
        do {
            _ = try await MCPApplyParameterPresetTool.run(
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

    func testValidationFailureIsAtomic() async throws {
        // Insert a preset with an out-of-range value (umap_target_dimension valid range is 5...100).
        try writePreset(
            name: "Bad Preset",
            settings: [
                AppSettings.chunkSize: "1500",          // valid
                AppSettings.umapTargetDimension: "999"  // INVALID
            ]
        )

        let beforeChunk = try readValue(AppSettings.chunkSize)
        let beforeUMAP = try readValue(AppSettings.umapTargetDimension)

        do {
            _ = try await MCPApplyParameterPresetTool.run(
                arguments: ["name": .string("Bad Preset")]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains(AppSettings.umapTargetDimension),
                "Error should mention the offending key; was: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }

        // Atomicity: chunk_size must NOT have been written.
        XCTAssertEqual(try readValue(AppSettings.chunkSize), beforeChunk)
        XCTAssertEqual(try readValue(AppSettings.umapTargetDimension), beforeUMAP)
    }

    func testTriggersDidUpdateSettingsForAffectedCategories() async throws {
        // Build a preset that changes embedding settings — this is the only
        // category whose `didUpdateSettings` produces an observable side-effect:
        // it rewrites `active_embedding_dimension` via rebuildVec0TablesIfNeeded.
        try writePreset(
            name: "Embedding Flip",
            settings: [
                AppSettings.embeddingProvider: "openrouter",
                AppSettings.embeddingDimension: "1024"
            ]
        )

        let before = try readValue(AppSettings.activeEmbeddingDimension)

        _ = try await MCPApplyParameterPresetTool.run(
            arguments: ["name": .string("Embedding Flip")]
        )

        let after = try readValue(AppSettings.activeEmbeddingDimension)
        XCTAssertEqual(after, "1024")
        XCTAssertNotEqual(before, after)
    }
}
