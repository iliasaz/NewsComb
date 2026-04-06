import Foundation
import GRDB
import SQLiteExtensions

/// Read-only access to the NewsComb SQLite database.
///
/// Opens the database in read-only mode with WAL journal so the MCP server
/// can query while the main app writes without blocking.
/// Loads the sqlite-vec extension for vector similarity search.
final class ReadOnlyDatabase: Sendable {
    let dbPool: DatabasePool

    init(path: String) throws {
        // Register sqlite-vec as an auto-extension before opening any connection.
        // This makes vec_distance_cosine() and other vec0 functions available.
        initialize_sqlite3_extensions()

        var config = Configuration()
        config.readonly = true
        config.foreignKeysEnabled = false // Read-only, no need for FK enforcement
        dbPool = try DatabasePool(path: path, configuration: config)
    }

    func read<T>(_ block: (Database) throws -> T) throws -> T {
        try dbPool.read(block)
    }
}
