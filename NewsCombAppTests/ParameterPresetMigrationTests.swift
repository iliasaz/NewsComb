import XCTest
import GRDB
@testable import NewsCombApp

/// Tests for the `parameter_preset` table migration and built-in preset
/// seeding logic. These tests run against an in-memory `DatabaseQueue`
/// and exercise the static helpers that mirror the production migration —
/// the live `Database.init(directory:)` path is not invoked because it
/// creates ~30 tables and depends on SQLiteExtensions being initialized.
final class ParameterPresetMigrationTests: XCTestCase {

    // MARK: - Test helpers

    /// Builds an in-memory database with only the `parameter_preset` table
    /// and seeds the built-in presets via the production helpers.
    private func makeMigratedDatabase() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try Database.createParameterPresetTable(db)
            try Database.seedDefaultPresets(db)
        }
        return dbQueue
    }

    /// Decodes the `settings_json` column for a named preset.
    private func decodedSettings(name: String, in dbQueue: DatabaseQueue) throws -> [String: String] {
        try dbQueue.read { db in
            guard let preset = try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db) else {
                throw NSError(domain: "ParameterPresetMigrationTests", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "Preset '\(name)' not found"
                ])
            }
            guard let data = preset.settingsJSON.data(using: .utf8) else {
                throw NSError(domain: "ParameterPresetMigrationTests", code: 2, userInfo: [
                    NSLocalizedDescriptionKey: "settings_json is not valid UTF-8"
                ])
            }
            guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
                throw NSError(domain: "ParameterPresetMigrationTests", code: 3, userInfo: [
                    NSLocalizedDescriptionKey: "settings_json is not a [String: String] dictionary"
                ])
            }
            return dict
        }
    }

    // MARK: - Schema

    func testMigrationCreatesParameterPresetTable() throws {
        let dbQueue = try makeMigratedDatabase()
        try dbQueue.read { db in
            let exists = try db.tableExists("parameter_preset")
            XCTAssertTrue(exists, "parameter_preset table should exist after migration")
        }
    }

    func testIndexExists() throws {
        let dbQueue = try makeMigratedDatabase()
        try dbQueue.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'index' AND name = 'idx_parameter_preset_name'"
            )
            XCTAssertNotNil(row, "idx_parameter_preset_name index should exist")
        }
    }

    // MARK: - Built-in seeds

    func testNewsIntelligencePresetSeeded() throws {
        let dbQueue = try makeMigratedDatabase()

        let preset: ParameterPreset? = try dbQueue.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == "News Intelligence")
                .fetchOne(db)
        }

        guard let preset else {
            XCTFail("News Intelligence preset should be seeded")
            return
        }

        XCTAssertTrue(preset.isBuiltin, "News Intelligence should be marked is_builtin")
        XCTAssertNotNil(preset.description, "News Intelligence should have a description")
        XCTAssertFalse(preset.description?.isEmpty ?? true, "Description should be non-empty")

        let settings = try decodedSettings(name: "News Intelligence", in: dbQueue)
        XCTAssertEqual(settings["chunk_size"], "800")
        XCTAssertEqual(settings["umap_target_dimension"], "25")
        XCTAssertEqual(settings["distillation_enabled"], "false")
        XCTAssertEqual(settings["extraction_temperature"], "0.33")
        XCTAssertNotNil(settings["extraction_system_prompt"])
        XCTAssertFalse(settings["extraction_system_prompt"]?.isEmpty ?? true)
        XCTAssertNotNil(settings["cluster_labeling_system_prompt"])
    }

    func testCodebaseIntelligencePresetSeeded() throws {
        let dbQueue = try makeMigratedDatabase()

        let preset: ParameterPreset? = try dbQueue.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == "Codebase Intelligence")
                .fetchOne(db)
        }

        guard let preset else {
            XCTFail("Codebase Intelligence preset should be seeded")
            return
        }

        XCTAssertTrue(preset.isBuiltin, "Codebase Intelligence should be marked is_builtin")
        XCTAssertNotNil(preset.description, "Codebase Intelligence should have a description")
        XCTAssertFalse(preset.description?.isEmpty ?? true, "Description should be non-empty")

        let settings = try decodedSettings(name: "Codebase Intelligence", in: dbQueue)
        XCTAssertEqual(settings["chunk_size"], "1200")
        XCTAssertEqual(settings["umap_target_dimension"], "15")
        XCTAssertEqual(settings["distillation_enabled"], "true")
        XCTAssertEqual(settings["extraction_temperature"], "0.2")
        XCTAssertEqual(settings["hdbscan_min_cluster_size"], "15")
        XCTAssertEqual(settings["hdbscan_min_samples"], "5")
        XCTAssertEqual(settings["umap_n_neighbors"], "10")
        XCTAssertEqual(settings["on_device_chunk_size"], "800")

        // The codebase extraction prompt should be present and contain
        // a hallmark phrase from the codebase-tuned variant.
        guard let prompt = settings["extraction_system_prompt"] else {
            XCTFail("extraction_system_prompt missing")
            return
        }
        XCTAssertTrue(
            prompt.contains("software project"),
            "Codebase extraction prompt should reference 'software project'"
        )
    }

    // MARK: - Idempotence

    func testReseedingDoesNotOverwriteUserEdits() throws {
        let dbQueue = try makeMigratedDatabase()

        // Mutate the description of the News Intelligence preset.
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE parameter_preset SET description = ? WHERE name = ?",
                arguments: ["Edited by user", "News Intelligence"]
            )
        }

        // Re-run the seed; INSERT OR IGNORE should preserve our edit.
        try dbQueue.write { db in
            try Database.seedDefaultPresets(db)
        }

        let edited: String? = try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT description FROM parameter_preset WHERE name = ?",
                arguments: ["News Intelligence"]
            )
        }
        XCTAssertEqual(edited, "Edited by user", "User edits should be preserved across re-seeding")
    }
}
