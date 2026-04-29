import Foundation
import GRDB
import MCP

/// Deletes a user-defined `parameter_preset` row. Built-in presets are
/// protected — use `reset_parameter_preset` to restore their defaults.
///
/// Phase 3 of issue #36.
enum MCPDeleteParameterPresetTool {
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

        if preset.isBuiltin {
            throw MCPToolError.invalidParameter(
                "name",
                detail: "built-in preset '\(name)' cannot be deleted; use reset_parameter_preset to restore defaults."
            )
        }

        do {
            try Database.current.write { db in
                try db.execute(
                    sql: "DELETE FROM parameter_preset WHERE name = ?",
                    arguments: [name]
                )
            }
        } catch {
            throw MCPToolError.database(error)
        }

        return "Deleted preset '\(name)'."
    }
}
