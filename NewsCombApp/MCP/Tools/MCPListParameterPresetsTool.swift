import Foundation
import GRDB
import MCP

/// Returns every row in `parameter_preset` as a JSON array.
///
/// Phase 3 of issue #36. Built-in presets sort first (`is_builtin DESC`),
/// then user presets alphabetically by name. The returned shape is a
/// trimmed summary suitable for display in a picker — full preset bodies
/// are returned by `get_parameter_preset`.
enum MCPListParameterPresetsTool {
    static func run(arguments: [String: Value]) async throws -> String {
        let rows: [ParameterPreset] = try Database.current.read { db in
            try ParameterPreset
                .order(
                    ParameterPreset.Columns.isBuiltin.desc,
                    ParameterPreset.Columns.name.asc
                )
                .fetchAll(db)
        }

        let payload: [[String: Any]] = rows.map { row in
            [
                "name": row.name,
                "description": row.description ?? "",
                "is_builtin": row.isBuiltin,
                "updated_at": row.updatedAt
            ]
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .prettyPrinted]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPToolError(message: "Failed to encode preset list JSON output.")
        }
        return json
    }
}
