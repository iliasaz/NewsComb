import Foundation
import GRDB
import MCP

/// Updates an existing `parameter_preset` row by merging supplied fields
/// into it. Built-in presets can be edited (description and settings); the
/// `is_builtin` flag is never changed. Validation happens before any write.
///
/// Phase 3 of issue #36.
enum MCPUpdateParameterPresetTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw MCPToolError.missingParameter("name")
        }

        // Load existing row.
        let existing: ParameterPreset? = try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
        guard let preset = existing else {
            throw MCPToolError.notFound("parameter preset '\(name)'")
        }

        // Resolve description: omitted → preserve.
        let newDescription: String?
        if let provided = arguments["description"]?.stringValue {
            newDescription = provided
        } else {
            newDescription = preset.description
        }

        // Resolve settings: omitted → preserve; provided → merge.
        let newSettingsJSON: String
        if let settingsValue = arguments["settings"] {
            guard let rawSettings = settingsValue.objectValue else {
                throw MCPToolError.invalidParameter(
                    "settings",
                    detail: "must be an object mapping setting keys to string values."
                )
            }

            // Coerce supplied entries.
            var supplied: [String: String] = [:]
            supplied.reserveCapacity(rawSettings.count)
            for (key, value) in rawSettings {
                guard let stringValue = value.stringValue else {
                    throw MCPToolError.invalidParameter(
                        "settings",
                        detail: "value for '\(key)' must be a string."
                    )
                }
                supplied[key] = stringValue
            }

            // Reject unknown keys.
            for key in supplied.keys where SettingsCategory.category(forKey: key) == nil {
                throw MCPToolError.invalidParameter(
                    "settings",
                    detail: "key '\(key)' does not belong to any known SettingsCategory."
                )
            }

            // Validate every supplied value.
            for (key, value) in supplied {
                do {
                    try SettingsValidator.validate(key, value)
                } catch let error as SettingsValidator.ValidationError {
                    throw MCPToolError.invalidParameter(
                        key,
                        detail: error.errorDescription ?? "validation failed"
                    )
                }
            }

            // Merge into existing settings.
            var merged: [String: String] = [:]
            if let data = preset.settingsJSON.data(using: .utf8),
               let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
                merged = dict
            }
            for (key, value) in supplied {
                merged[key] = value
            }

            let data = try JSONSerialization.data(
                withJSONObject: merged,
                options: [.sortedKeys]
            )
            guard let json = String(data: data, encoding: .utf8) else {
                throw MCPToolError(message: "Failed to encode merged settings.")
            }
            newSettingsJSON = json
        } else {
            newSettingsJSON = preset.settingsJSON
        }

        do {
            try Database.current.write { db in
                try db.execute(
                    sql: """
                        UPDATE parameter_preset
                        SET description = ?, settings_json = ?, updated_at = unixepoch()
                        WHERE name = ?
                    """,
                    arguments: [newDescription, newSettingsJSON, name]
                )
            }
        } catch {
            throw MCPToolError.database(error)
        }

        return "Updated preset '\(name)'."
    }
}
