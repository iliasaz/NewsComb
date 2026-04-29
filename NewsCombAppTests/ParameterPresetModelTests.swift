import XCTest
import GRDB
@testable import NewsCombApp

/// Tests for the `ParameterPreset` GRDB record type.
final class ParameterPresetModelTests: XCTestCase {

    // MARK: - Test helpers

    /// Builds an in-memory database with just the `parameter_preset` table.
    private func makeEmptyDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try Database.createParameterPresetTable(db)
        }
        return dbQueue
    }

    // MARK: - Round-trip

    func testRoundTripInsertFetch() throws {
        let dbQueue = try makeEmptyDatabase()

        var preset = ParameterPreset(
            id: nil,
            name: "Test Preset",
            description: "A test preset",
            settingsJSON: #"{"chunk_size":"1000"}"#,
            isBuiltin: false,
            createdAt: 1000.0,
            updatedAt: 1500.0
        )

        try dbQueue.write { db in
            try preset.insert(db)
        }
        XCTAssertNotNil(preset.id, "Inserted record should have its rowid populated via didInsert")

        let fetched: ParameterPreset? = try dbQueue.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == "Test Preset")
                .fetchOne(db)
        }

        guard let fetched else {
            XCTFail("Round-tripped preset should be fetchable")
            return
        }
        XCTAssertEqual(fetched.name, "Test Preset")
        XCTAssertEqual(fetched.description, "A test preset")
        XCTAssertEqual(fetched.settingsJSON, #"{"chunk_size":"1000"}"#)
        XCTAssertFalse(fetched.isBuiltin)
        XCTAssertEqual(fetched.createdAt, 1000.0)
        XCTAssertEqual(fetched.updatedAt, 1500.0)
    }

    // MARK: - Column mapping

    func testColumnsMappingMatchesSchema() throws {
        let dbQueue = try makeEmptyDatabase()

        // Insert via raw SQL using the underlying snake_case column names.
        try dbQueue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO parameter_preset
                        (name, description, settings_json, is_builtin, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: ["Builtin", "Schema check", "{}", 1, 100.0, 200.0]
            )
        }

        let fetched: ParameterPreset? = try dbQueue.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == "Builtin")
                .fetchOne(db)
        }

        guard let fetched else {
            XCTFail("Should fetch the row inserted via raw SQL")
            return
        }
        XCTAssertTrue(fetched.isBuiltin, "is_builtin should map to isBuiltin")
        XCTAssertEqual(fetched.createdAt, 100.0, "created_at should map to createdAt")
        XCTAssertEqual(fetched.updatedAt, 200.0, "updated_at should map to updatedAt")
        XCTAssertEqual(fetched.settingsJSON, "{}")
    }

    // MARK: - builtinSettings helper

    func testBuiltinSettingsHelperReturnsKnownPresets() {
        let news = ParameterPreset.builtinSettings(forPresetNamed: "News Intelligence")
        XCTAssertNotNil(news)
        XCTAssertEqual(news?["chunk_size"], "800")
        XCTAssertEqual(news?["umap_target_dimension"], "25")
        XCTAssertEqual(news?["distillation_enabled"], "false")

        let codebase = ParameterPreset.builtinSettings(forPresetNamed: "Codebase Intelligence")
        XCTAssertNotNil(codebase)
        XCTAssertEqual(codebase?["chunk_size"], "1200")
        XCTAssertEqual(codebase?["umap_target_dimension"], "15")
        XCTAssertEqual(codebase?["distillation_enabled"], "true")

        let unknown = ParameterPreset.builtinSettings(forPresetNamed: "Made-Up Preset")
        XCTAssertNil(unknown, "Unknown preset name should return nil")
    }
}
