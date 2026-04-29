import Foundation
import GRDB
import MCP

/// Returns `app_settings` rows grouped by `SettingsCategory`.
///
/// Phase 2 of issue #35. Called by MCP clients to inspect the current
/// configuration. Secret keys (e.g. API tokens) are redacted unless the
/// caller explicitly opts in via `include_secrets`.
///
/// Output format: a JSON object whose top-level keys are category names
/// and whose values are `[String: String]` dictionaries of setting keys to
/// their string values. Missing rows surface as `""` so the schema is stable
/// for clients regardless of which keys have been seeded.
enum MCPGetSettingsTool {
    static func run(arguments: [String: Value]) async throws -> String {
        // Optional category filter — if present, must be a known SettingsCategory.
        let categories: [SettingsCategory]
        if let raw = arguments["category"]?.stringValue {
            guard let category = SettingsCategory(rawValue: raw) else {
                let allowed = SettingsCategory.allCases
                    .map { "'\($0.rawValue)'" }
                    .joined(separator: ", ")
                throw MCPToolError.invalidParameter(
                    "category",
                    detail: "'\(raw)' is not a valid category. Allowed: \(allowed)."
                )
            }
            categories = [category]
        } else {
            categories = SettingsCategory.allCases
        }

        let includeSecrets = arguments["include_secrets"]?.boolValue ?? false

        // Build [category: [key: value]] in a single read transaction.
        let payload: [String: [String: String]] = try Database.current.read { db in
            var result: [String: [String: String]] = [:]
            for category in categories {
                var bucket: [String: String] = [:]
                for key in category.keys {
                    if !includeSecrets, SettingsCategory.secretKeys.contains(key) {
                        bucket[key] = "<redacted>"
                        continue
                    }
                    let value = try AppSettings
                        .filter(AppSettings.Columns.key == key)
                        .fetchOne(db)?
                        .value ?? ""
                    bucket[key] = value
                }
                result[category.rawValue] = bucket
            }
            return result
        }

        let data = try JSONSerialization.data(
            withJSONObject: payload,
            options: [.sortedKeys, .prettyPrinted]
        )
        guard let json = String(data: data, encoding: .utf8) else {
            throw MCPToolError(message: "Failed to encode settings JSON output.")
        }
        return json
    }
}
