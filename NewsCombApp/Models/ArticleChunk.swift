import Foundation
import GRDB

/// Represents a chunk of text from an article for fine-grained provenance tracking.
struct ArticleChunk: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var feedItemId: Int64
    var chunkIndex: Int
    var content: String
    var createdAt: Date

    static let databaseTableName = "article_chunk"

    enum CodingKeys: String, CodingKey {
        case id
        case feedItemId = "feed_item_id"
        case chunkIndex = "chunk_index"
        case content
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id
        case feedItemId = "feed_item_id"
        case chunkIndex = "chunk_index"
        case content
        case createdAt = "created_at"
    }

    init(
        id: Int64? = nil,
        feedItemId: Int64,
        chunkIndex: Int,
        content: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.feedItemId = feedItemId
        self.chunkIndex = chunkIndex
        self.content = content
        self.createdAt = createdAt
    }
}

/// Metadata for tracking computed chunk embeddings.
struct ChunkEmbeddingMetadata: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64? { chunkId }
    var chunkId: Int64
    var computedAt: Date
    var modelName: String?
    var embeddingVersion: Int

    static let databaseTableName = "chunk_embedding_metadata"

    enum CodingKeys: String, CodingKey {
        case chunkId = "chunk_id"
        case computedAt = "computed_at"
        case modelName = "model_name"
        case embeddingVersion = "embedding_version"
    }

    enum Columns: String, ColumnExpression {
        case chunkId = "chunk_id"
        case computedAt = "computed_at"
        case modelName = "model_name"
        case embeddingVersion = "embedding_version"
    }

    init(
        chunkId: Int64,
        computedAt: Date = Date(),
        modelName: String? = nil,
        embeddingVersion: Int = 1
    ) {
        self.chunkId = chunkId
        self.computedAt = computedAt
        self.modelName = modelName
        self.embeddingVersion = embeddingVersion
    }

    /// Checks if a chunk already has an embedding computed.
    static func hasEmbedding(_ db: GRDB.Database, chunkId: Int64) throws -> Bool {
        try ChunkEmbeddingMetadata
            .filter(Columns.chunkId == chunkId)
            .fetchCount(db) > 0
    }

    /// Marks an embedding as computed for a chunk.
    static func markEmbeddingComputed(_ db: GRDB.Database, chunkId: Int64, modelName: String?) throws {
        var metadata = ChunkEmbeddingMetadata(chunkId: chunkId, modelName: modelName)
        try metadata.insert(db, onConflict: .replace)
    }
}
