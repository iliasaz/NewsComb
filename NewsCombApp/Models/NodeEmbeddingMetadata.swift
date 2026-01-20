import Foundation
import GRDB

/// Metadata tracking for node embeddings.
/// This is a companion table to the sqlite-vec virtual table which cannot store metadata.
struct NodeEmbeddingMetadata: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "node_embedding_metadata"

    var nodeId: Int64
    var computedAt: Date
    var modelName: String?
    var embeddingVersion: Int

    enum Columns: String, ColumnExpression {
        case nodeId = "node_id"
        case computedAt = "computed_at"
        case modelName = "model_name"
        case embeddingVersion = "embedding_version"
    }

    init(nodeId: Int64, computedAt: Date = Date(), modelName: String? = nil, embeddingVersion: Int = 1) {
        self.nodeId = nodeId
        self.computedAt = computedAt
        self.modelName = modelName
        self.embeddingVersion = embeddingVersion
    }
}

extension NodeEmbeddingMetadata {
    /// Check if a node already has an embedding computed.
    static func hasEmbedding(_ db: GRDB.Database, nodeId: Int64) throws -> Bool {
        try NodeEmbeddingMetadata
            .filter(Columns.nodeId == nodeId)
            .fetchCount(db) > 0
    }

    /// Get node IDs that don't have embeddings yet.
    static func nodesNeedingEmbeddings(_ db: GRDB.Database, nodeIds: [Int64]) throws -> [Int64] {
        guard !nodeIds.isEmpty else { return [] }

        let existingIds = try Int64.fetchAll(db, sql: """
            SELECT node_id FROM node_embedding_metadata WHERE node_id IN (\(nodeIds.map { String($0) }.joined(separator: ",")))
        """)

        return nodeIds.filter { !existingIds.contains($0) }
    }

    /// Mark a node as having an embedding computed.
    static func markEmbeddingComputed(
        _ db: GRDB.Database,
        nodeId: Int64,
        modelName: String?
    ) throws {
        try db.execute(sql: """
            INSERT INTO node_embedding_metadata (node_id, computed_at, model_name, embedding_version)
            VALUES (?, unixepoch(), ?, 1)
            ON CONFLICT(node_id) DO UPDATE SET
                computed_at = excluded.computed_at,
                model_name = excluded.model_name
        """, arguments: [nodeId, modelName])
    }

    /// Remove embedding metadata for a node (used when node is deleted or merged).
    static func removeMetadata(_ db: GRDB.Database, nodeId: Int64) throws {
        try db.execute(sql: "DELETE FROM node_embedding_metadata WHERE node_id = ?", arguments: [nodeId])
    }
}
