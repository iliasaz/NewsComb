import Foundation
import GRDB

/// Protocol for database read access used by MCP tools.
/// Enables dependency injection for testing with in-memory databases.
protocol MCPDatabaseReader: Sendable {
    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T
}

/// Make the app's Database conform to MCPDatabaseReader.
extension Database: MCPDatabaseReader {}

/// Test-friendly database reader backed by an in-memory DatabaseQueue.
final class InMemoryDatabaseReader: MCPDatabaseReader, Sendable {
    let dbQueue: DatabaseQueue

    init(dbQueue: DatabaseQueue) {
        self.dbQueue = dbQueue
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }
}
