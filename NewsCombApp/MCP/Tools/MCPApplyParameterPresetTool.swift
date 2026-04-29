import Foundation
import GRDB
import MCP
import OSLog

/// Applies a `parameter_preset` to the workspace's `app_settings` table.
///
/// Phase 3 of issue #36. Workflow:
///   1. Look up the preset by name.
///   2. Parse `settings_json` into `[String: String]`.
///   3. Group keys by `SettingsCategory`. Forward-compat: keys that don't
///      belong to any known category are skipped with a logged warning.
///   4. Validate every value via `SettingsValidator` BEFORE any write.
///      Atomic: any failure aborts the entire batch.
///   5. Upsert each key/value into `app_settings`.
///   6. Notify `MCPAppCoordinator` once per affected category so side
///      effects (e.g. vec0 rebuild on `.llm`) fire.
enum MCPApplyParameterPresetTool {

    private static let logger = Logger(subsystem: "com.newscomb.app", category: "MCPApplyPreset")

    static func run(arguments: [String: Value]) async throws -> String {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw MCPToolError.missingParameter("name")
        }

        // 1. Load preset.
        let row: ParameterPreset? = try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
        guard let preset = row else {
            throw MCPToolError.notFound("parameter preset '\(name)'")
        }

        // 2. Parse settings JSON.
        guard let data = preset.settingsJSON.data(using: .utf8),
              let parsed = try JSONSerialization.jsonObject(with: data) as? [String: String] else {
            throw MCPToolError(message: "Preset '\(name)' has invalid settings_json.")
        }

        // 3. Bucket keys by category; skip unknown keys with a warning.
        var byCategory: [SettingsCategory: [(key: String, value: String)]] = [:]
        for (key, value) in parsed {
            guard let category = SettingsCategory.category(forKey: key) else {
                logger.warning(
                    "Preset '\(name, privacy: .public)' references unknown settings key '\(key, privacy: .public)' — skipping."
                )
                continue
            }
            byCategory[category, default: []].append((key: key, value: value))
        }

        // 4. Atomic validation: validate every value BEFORE writing anything.
        for (_, updates) in byCategory {
            for update in updates {
                do {
                    try SettingsValidator.validate(update.key, update.value)
                } catch let error as SettingsValidator.ValidationError {
                    throw MCPToolError.invalidParameter(
                        update.key,
                        detail: error.errorDescription ?? "validation failed"
                    )
                }
            }
        }

        let totalCount = byCategory.values.reduce(0) { $0 + $1.count }
        let affectedCategories = byCategory.keys

        // 5. Single transaction: upsert every key.
        do {
            try Database.current.write { db in
                for updates in byCategory.values {
                    for update in updates {
                        try db.execute(
                            sql: """
                                INSERT INTO app_settings (key, value) VALUES (?, ?)
                                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                            """,
                            arguments: [update.key, update.value]
                        )
                    }
                }
            }
        } catch {
            throw MCPToolError.database(error)
        }

        // 6. Fire side-effect coordinator once per affected category.
        for category in affectedCategories {
            await MCPAppCoordinator.shared.didUpdateSettings(category: category)
        }

        let categoryCount = affectedCategories.count
        let plural = totalCount == 1 ? "" : "s"
        let catPlural = categoryCount == 1 ? "y" : "ies"
        return "Applied preset '\(name)' (\(totalCount) setting\(plural) across \(categoryCount) categor\(catPlural))."
    }
}
