import Foundation
import GRDB
import MCP

/// Restores a built-in `parameter_preset` to its seeded defaults. For
/// user-defined presets it is a friendly no-op (no error) since "reset"
/// is undefined for presets the user authored themselves.
///
/// Phase 3 of issue #36.
enum MCPResetParameterPresetTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let name = arguments["name"]?.stringValue, !name.isEmpty else {
            throw MCPToolError.missingParameter("name")
        }

        let existing: ParameterPreset? = try Database.current.read { db in
            try ParameterPreset
                .filter(ParameterPreset.Columns.name == name)
                .fetchOne(db)
        }
        guard let preset = existing else {
            throw MCPToolError.notFound("parameter preset '\(name)'")
        }

        if !preset.isBuiltin {
            return "Preset '\(name)' is user-defined; reset is a no-op."
        }

        guard let seed = ParameterPreset.builtinSettings(forPresetNamed: name) else {
            // Should not happen for a known built-in, but surface a clear error.
            throw MCPToolError.notFound("seeded defaults for built-in preset '\(name)'")
        }

        let data = try JSONSerialization.data(
            withJSONObject: seed,
            options: [.sortedKeys]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPToolError(message: "Failed to encode seeded settings.")
        }

        // Pick the seeded description that matches the built-in name.
        let description: String
        switch name {
        case ParameterPreset.newsIntelligenceName:
            description = ParameterPreset.newsIntelligenceDescription
        case ParameterPreset.codebaseIntelligenceName:
            description = ParameterPreset.codebaseIntelligenceDescription
        default:
            description = preset.description ?? ""
        }

        do {
            try Database.current.write { db in
                try db.execute(
                    sql: """
                        UPDATE parameter_preset
                        SET settings_json = ?, description = ?, updated_at = unixepoch()
                        WHERE name = ?
                    """,
                    arguments: [json, description, name]
                )
            }
        } catch {
            throw MCPToolError.database(error)
        }

        return "Reset preset '\(name)' to seeded defaults."
    }
}
