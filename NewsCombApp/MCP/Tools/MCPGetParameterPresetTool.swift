import Foundation
import GRDB
import MCP

/// Returns a single `parameter_preset` row, including its parsed
/// `settings_json` body. Secret keys (per `SettingsCategory.secretKeys`)
/// are redacted unless the caller passes `include_secrets=true`.
///
/// Phase 3 of issue #36.
enum MCPGetParameterPresetTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw MCPToolError.missingParameter("name")
        }
        let includeSecrets = arguments["include_secrets"]?.boolValue ?? false

        let row: ParameterPreset? = try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
        guard let preset = row else {
            throw MCPToolError.notFound("parameter preset '\(name)'")
        }

        // Parse the settings JSON; it must be a flat [String: String] map.
        let parsedSettings: [String: String]
        if let data = preset.settingsJSON.data(using: .utf8),
           let dict = try JSONSerialization.jsonObject(with: data) as? [String: String] {
            parsedSettings = dict
        } else {
            parsedSettings = [:]
        }

        // Redact secret values unless caller opts in.
        var settings = parsedSettings
        if !includeSecrets {
            for key in settings.keys where SettingsCategory.secretKeys.contains(key) {
                settings[key] = "<redacted>"
            }
        }

        let payload: [String: Any] = [
            "name": preset.name,
            "description": preset.description ?? "",
            "is_builtin": preset.isBuiltin,
            "created_at": preset.createdAt,
            "updated_at": preset.updatedAt,
            "settings": settings
        ]

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .prettyPrinted]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPToolError(message: "Failed to encode preset JSON output.")
        }
        return json
    }
}
