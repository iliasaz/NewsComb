import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the `update_settings` MCP tool, which writes `app_settings`
/// rows after validating every value atomically against `SettingsValidator`.
final class MCPUpdateSettingsToolTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPUpdateSettingsTests-\(UUID().uuidString)")
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

    // MARK: - Tests

    func testHappyPathPersists() async throws {
        let args: [String: Value] = [
            "category": .string("clustering"),
            "settings": .object([
                AppSettings.umapTargetDimension: .string("30"),
                AppSettings.hdbscanMinSamples: .string("5")
            ])
        ]
        let result = try await MCPUpdateSettingsTool.run(arguments: args)
        XCTAssertTrue(result.localizedStandardContains("clustering"))
        XCTAssertTrue(result.contains("2"))

        XCTAssertEqual(try readValue(AppSettings.umapTargetDimension), "30")
        XCTAssertEqual(try readValue(AppSettings.hdbscanMinSamples), "5")
    }

    func testMissingCategoryThrowsMissingParameter() async {
        do {
            _ = try await MCPUpdateSettingsTool.run(
                arguments: ["settings": .object([:])]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.localizedStandardContains("category"),
                "Got: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }
    }

    func testMissingSettingsThrowsMissingParameter() async {
        do {
            _ = try await MCPUpdateSettingsTool.run(
                arguments: ["category": .string("clustering")]
            )
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.localizedStandardContains("settings"),
                "Got: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }
    }

    func testUnknownKeyForCategoryRejected() async throws {
        // llm_provider belongs to the .llm category, not .clustering.
        let originalUMAP = try readValue(AppSettings.umapTargetDimension)

        let args: [String: Value] = [
            "category": .string("clustering"),
            "settings": .object([
                AppSettings.llmProvider: .string("ollama")
            ])
        ]
        do {
            _ = try await MCPUpdateSettingsTool.run(arguments: args)
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains(AppSettings.llmProvider),
                "Error should mention the offending key; was: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }

        // No unrelated rows should have changed.
        let afterUMAP = try readValue(AppSettings.umapTargetDimension)
        XCTAssertEqual(originalUMAP, afterUMAP)

        // The rejected setting must NOT have been written.
        // (llm_provider is seeded with default empty string; ollama would be the new value.)
        let providerValue = try readValue(AppSettings.llmProvider) ?? ""
        XCTAssertNotEqual(providerValue, "ollama")
    }

    func testInvalidValueRejectedAndAtomic() async throws {
        // umap_target_dimension valid range is 5...100. "999" is out of range.
        // Pair it with a valid setting; the whole batch must be rejected
        // and neither value should be persisted.
        let beforeMinSamples = try readValue(AppSettings.hdbscanMinSamples)
        let beforeUMAP = try readValue(AppSettings.umapTargetDimension)

        let args: [String: Value] = [
            "category": .string("clustering"),
            "settings": .object([
                AppSettings.hdbscanMinSamples: .string("7"),
                AppSettings.umapTargetDimension: .string("999")
            ])
        ]
        do {
            _ = try await MCPUpdateSettingsTool.run(arguments: args)
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.contains(AppSettings.umapTargetDimension),
                "Error should mention the offending key; was: \(error.message)"
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)")
        }

        // Atomicity check: the valid sibling key must NOT have been written.
        XCTAssertEqual(try readValue(AppSettings.hdbscanMinSamples), beforeMinSamples)
        XCTAssertEqual(try readValue(AppSettings.umapTargetDimension), beforeUMAP)
    }

    func testEmbeddingDimensionTriggersVec0Rebuild() async throws {
        // After Database.init, active_embedding_dimension is set to whatever the
        // default vec0 tables were created with (768 for Nomic). Switching the
        // embedding provider to OpenRouter and changing the dimension should
        // cause didUpdateSettings(.llm) to invoke rebuildVec0TablesIfNeeded()
        // which writes a new `active_embedding_dimension` row.
        //
        // We assert the rebuild happened by reading active_embedding_dimension
        // before and after — it should reflect the new desired dim (1024).
        let beforeActive = try readValue(AppSettings.activeEmbeddingDimension)

        let args: [String: Value] = [
            "category": .string("llm"),
            "settings": .object([
                AppSettings.embeddingProvider: .string("openrouter"),
                AppSettings.embeddingDimension: .string("1024")
            ])
        ]
        let result = try await MCPUpdateSettingsTool.run(arguments: args)
        XCTAssertTrue(result.localizedStandardContains("llm"))

        // Both updates persisted.
        XCTAssertEqual(try readValue(AppSettings.embeddingProvider), "openrouter")
        XCTAssertEqual(try readValue(AppSettings.embeddingDimension), "1024")

        // The vec0 rebuild should have run, updating active_embedding_dimension.
        let afterActive = try readValue(AppSettings.activeEmbeddingDimension)
        XCTAssertEqual(afterActive, "1024")
        XCTAssertNotEqual(beforeActive, afterActive)
    }
}
