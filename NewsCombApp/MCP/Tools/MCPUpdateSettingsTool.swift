import Foundation
import GRDB
import MCP

/// Writes `app_settings` rows for one `SettingsCategory` after atomically
/// validating every value via `SettingsValidator`.
///
/// Phase 2 of issue #35. Validation is all-or-nothing: if any value is
/// invalid the entire batch is rejected and no rows are written. After
/// successful writes the side-effect coordinator
/// (`MCPAppCoordinator.didUpdateSettings`) is invoked so the rest of the
/// app can react to the change (e.g. rebuilding `vec0` tables when the
/// embedding dimension changed).
enum MCPUpdateSettingsTool {
    static func run(arguments: [String: Value]) async throws -> String {
        // 1. Required: category.
        guard let raw = arguments["category"]?.stringValue, !raw.isEmpty else {
            throw MCPToolError.missingParameter("category")
        }
        guard let category = SettingsCategory(rawValue: raw) else {
            let allowed = SettingsCategory.allCases
                .map { "'\($0.rawValue)'" }
                .joined(separator: ", ")
            throw MCPToolError.invalidParameter(
                "category",
                detail: "'\(raw)' is not a valid category. Allowed: \(allowed)."
            )
        }

        // 2. Required: settings object.
        guard let settingsValue = arguments["settings"] else {
            throw MCPToolError.missingParameter("settings")
        }
        guard let rawSettings = settingsValue.objectValue else {
            throw MCPToolError.invalidParameter(
                "settings",
                detail: "must be an object mapping setting keys to string values."
            )
        }

        // 3. Coerce every entry to (key: String, value: String). Reject any
        //    non-string value with a useful error.
        var updates: [(key: String, value: String)] = []
        updates.reserveCapacity(rawSettings.count)
        for (key, value) in rawSettings {
            guard let stringValue = value.stringValue else {
                throw MCPToolError.invalidParameter(
                    "settings",
                    detail: "value for '\(key)' must be a string."
                )
            }
            updates.append((key: key, value: stringValue))
        }

        // 4. Reject any key that doesn't belong to this category.
        let allowedKeys = Set(category.keys)
        let unknownKeys = updates.map(\.key).filter { !allowedKeys.contains($0) }
        if !unknownKeys.isEmpty {
            let validList = category.keys
                .map { "'\($0)'" }
                .joined(separator: ", ")
            let unknownList = unknownKeys
                .map { "'\($0)'" }
                .joined(separator: ", ")
            throw MCPToolError.invalidParameter(
                "settings",
                detail: """
                    Key(s) \(unknownList) do not belong to category '\(category.rawValue)'. \
                    Valid keys: \(validList).
                    """
            )
        }

        // 5. Atomic validation: validate ALL values BEFORE any database write.
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

        // 6. Write everything in a single transaction.
        do {
            try Database.current.write { db in
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
        } catch {
            throw MCPToolError.database(error)
        }

        // 7. Notify side-effect coordinator (e.g. trigger vec0 rebuild).
        await MCPAppCoordinator.shared.didUpdateSettings(category: category)

        let count = updates.count
        let plural = count == 1 ? "" : "s"
        return "Updated \(count) setting\(plural) in category '\(category.rawValue)'."
    }
}
