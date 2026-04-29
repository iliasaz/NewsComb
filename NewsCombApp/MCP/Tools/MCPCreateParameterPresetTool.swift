import Foundation
import GRDB
import MCP

/// Creates a new user-defined `parameter_preset` row.
///
/// Phase 3 of issue #36. Validates every supplied setting against the
/// same `SettingsValidator` rules used by `update_settings`. Rejects
/// keys that don't belong to any `SettingsCategory`. Refuses to overwrite
/// an existing preset (call `update_parameter_preset` to mutate one).
enum MCPCreateParameterPresetTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw MCPToolError.missingParameter("name")
        }
        guard let description = arguments["description"]?.stringValue else {
            throw MCPToolError.missingParameter("description")
        }
        guard let settingsValue = arguments["settings"] else {
            throw MCPToolError.missingParameter("settings")
        }
        guard let rawSettings = settingsValue.objectValue else {
            throw MCPToolError.invalidParameter(
                "settings",
                detail: "must be an object mapping setting keys to string values."
            )
        }

        // Coerce every entry to (String, String).
        var settings: [String: String] = [:]
        settings.reserveCapacity(rawSettings.count)
        for (key, value) in rawSettings {
            guard let stringValue = value.stringValue else {
                throw MCPToolError.invalidParameter(
                    "settings",
                    detail: "value for '\(key)' must be a string."
                )
            }
            settings[key] = stringValue
        }

        // Reject keys that don't belong to any known category.
        for key in settings.keys where SettingsCategory.category(forKey: key) == nil {
            throw MCPToolError.invalidParameter(
                "settings",
                detail: "key '\(key)' does not belong to any known SettingsCategory."
            )
        }

        // Validate every value before any write.
        for (key, value) in settings {
            do {
                try SettingsValidator.validate(key, value)
            } catch let error as SettingsValidator.ValidationError {
                throw MCPToolError.invalidParameter(
                    key,
                    detail: error.errorDescription ?? "validation failed"
                )
            }
        }

        // Pre-check duplicate (UNIQUE constraint would also catch this, but
        // the manual check yields a friendlier message).
        let existing: ParameterPreset? = try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
        if existing != nil {
            throw MCPToolError.invalidParameter(
                "name",
                detail: "a preset named '\(name)' already exists; use update_parameter_preset to modify it."
            )
        }

        // JSON-encode (sorted for deterministic output).
        let data = try JSONSerialization.data(
            withJSONObject: settings,
            options: [.sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPToolError(message: "Failed to encode preset settings.")
        }

        do {
            try Database.current.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO parameter_preset (name, description, settings_json, is_builtin, created_at, updated_at)
                        VALUES (?, ?, ?, 0, unixepoch(), unixepoch())
                    """,
                    arguments: [name, description, json]
                )
            }
        } catch {
            throw MCPToolError.database(error)
        }

        return "Created preset '\(name)'."
    }
}
