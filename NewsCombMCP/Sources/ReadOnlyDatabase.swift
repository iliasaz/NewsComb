import Foundation
import GRDB

/// Read-only access to the NewsComb SQLite database.
///
/// Opens the database in read-only mode with WAL journal so the MCP server
/// can query while the main app writes without blocking.
final class ReadOnlyDatabase: Sendable {
    let dbPool: DatabasePool

    init(path: String) throws {
        var config = Configuration()
        config.readonly = true
        config.foreignKeysEnabled = false // Read-only, no need for FK enforcement
        dbPool = try DatabasePool(path: path, configuration: config)
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }
}
