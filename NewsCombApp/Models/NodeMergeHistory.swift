import Foundation
import GRDB

/// Records the history of node merges for tracking and potential undo.
struct NodeMergeHistory: Identifiable, Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "node_merge_history"

    var id: Int64?
    var mergedAt: Date
    var keptNodeId: Int64
    var removedNodeId: Int64
    var removedNodeLabel: String
    var similarityScore: Double

    // Maps Swift property names to database column names for Codable encoding/decoding
    enum CodingKeys: String, CodingKey {
        case id
        case mergedAt = "merged_at"
        case keptNodeId = "kept_node_id"
        case removedNodeId = "removed_node_id"
        case removedNodeLabel = "removed_node_label"
        case similarityScore = "similarity_score"
    }

    enum Columns: String, ColumnExpression {
        case id
        case mergedAt = "merged_at"
        case keptNodeId = "kept_node_id"
        case removedNodeId = "removed_node_id"
        case removedNodeLabel = "removed_node_label"
        case similarityScore = "similarity_score"
    }

    init(
        id: Int64? = nil,
        mergedAt: Date = Date(),
        keptNodeId: Int64,
        removedNodeId: Int64,
        removedNodeLabel: String,
        similarityScore: Double
    ) {
        self.id = id
        self.mergedAt = mergedAt
        self.keptNodeId = keptNodeId
        self.removedNodeId = removedNodeId
        self.removedNodeLabel = removedNodeLabel
        self.similarityScore = similarityScore
    }
}

extension NodeMergeHistory {
    /// Record a merge operation.
    static func recordMerge(
        _ db: GRDB.Database,
        keptNodeId: Int64,
        removedNodeId: Int64,
        removedNodeLabel: String,
        similarityScore: Double
    ) throws {
        _ = try NodeMergeHistory(
            keptNodeId: keptNodeId,
            removedNodeId: removedNodeId,
            removedNodeLabel: removedNodeLabel,
            similarityScore: similarityScore
        ).inserted(db)
    }

    /// Get all merges for a specific kept node.
    static func mergesFor(_ db: GRDB.Database, keptNodeId: Int64) throws -> [NodeMergeHistory] {
        try NodeMergeHistory
            .filter(Columns.keptNodeId == keptNodeId)
            .order(Columns.mergedAt.desc)
            .fetchAll(db)
    }

    /// Get recent merge history.
    static func recentMerges(_ db: GRDB.Database, limit: Int = 100) throws -> [NodeMergeHistory] {
        try NodeMergeHistory
            .order(Columns.mergedAt.desc)
            .limit(limit)
            .fetchAll(db)
    }

    /// Get total count of merged nodes.
    static func totalMergeCount(_ db: GRDB.Database) throws -> Int {
        try NodeMergeHistory.fetchCount(db)
    }
}
