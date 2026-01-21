import Foundation
import GRDB
import OSLog

/// Service for managing query history persistence.
struct QueryHistoryService {
    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "QueryHistoryService")

    /// Saves a GraphRAGResponse to the query history.
    func save(_ response: GraphRAGResponse) throws {
        var item = QueryHistoryItem(from: response)
        try database.write { db in
            try item.insert(db)
        }
        logger.debug("Saved query to history: \(response.query.prefix(50), privacy: .public)")
    }

    /// Fetches all query history items, most recent first.
    func fetchAll() throws -> [QueryHistoryItem] {
        try database.read { db in
            try QueryHistoryItem
                .order(QueryHistoryItem.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    /// Fetches the most recent query history items up to a limit.
    func fetchRecent(limit: Int = 20) throws -> [QueryHistoryItem] {
        try database.read { db in
            try QueryHistoryItem
                .order(QueryHistoryItem.Columns.createdAt.desc)
                .limit(limit)
                .fetchAll(db)
        }
    }

    /// Fetches a single query history item by ID.
    func fetch(id: Int64) throws -> QueryHistoryItem? {
        try database.read { db in
            try QueryHistoryItem.fetchOne(db, key: id)
        }
    }

    /// Deletes a query history item by ID.
    func delete(id: Int64) throws {
        try database.write { db in
            _ = try QueryHistoryItem.deleteOne(db, key: id)
        }
        logger.debug("Deleted query history item: \(id)")
    }

    /// Deletes all query history.
    func deleteAll() throws {
        try database.write { db in
            _ = try QueryHistoryItem.deleteAll(db)
        }
        logger.info("Cleared all query history")
    }

    /// Gets the count of history items.
    func count() throws -> Int {
        try database.read { db in
            try QueryHistoryItem.fetchCount(db)
        }
    }
}
