import Foundation
import GRDB

/// Processing status for article hypergraph extraction.
enum HypergraphProcessingStatus: String, Codable, Sendable {
    case pending
    case processing
    case completed
    case failed
}

/// Tracks the hypergraph processing status for each article.
struct ArticleHypergraph: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var feedItemId: Int64
    var processedAt: Date
    var processingStatus: HypergraphProcessingStatus
    var errorMessage: String?
    var chunkCount: Int

    static let databaseTableName = "article_hypergraph"

    enum CodingKeys: String, CodingKey {
        case id
        case feedItemId = "feed_item_id"
        case processedAt = "processed_at"
        case processingStatus = "processing_status"
        case errorMessage = "error_message"
        case chunkCount = "chunk_count"
    }

    enum Columns: String, ColumnExpression {
        case id
        case feedItemId = "feed_item_id"
        case processedAt = "processed_at"
        case processingStatus = "processing_status"
        case errorMessage = "error_message"
        case chunkCount = "chunk_count"
    }

    init(
        id: Int64? = nil,
        feedItemId: Int64,
        processedAt: Date = Date(),
        processingStatus: HypergraphProcessingStatus = .pending,
        errorMessage: String? = nil,
        chunkCount: Int = 0
    ) {
        self.id = id
        self.feedItemId = feedItemId
        self.processedAt = processedAt
        self.processingStatus = processingStatus
        self.errorMessage = errorMessage
        self.chunkCount = chunkCount
    }
}

/// Links edges to their source articles with provenance information.
struct ArticleEdgeProvenance: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var edgeId: Int64
    var feedItemId: Int64
    var chunkIndex: Int?
    var chunkText: String?
    var confidence: Double?

    static let databaseTableName = "article_edge_provenance"

    enum CodingKeys: String, CodingKey {
        case id, confidence
        case edgeId = "edge_id"
        case feedItemId = "feed_item_id"
        case chunkIndex = "chunk_index"
        case chunkText = "chunk_text"
    }

    enum Columns: String, ColumnExpression {
        case id
        case edgeId = "edge_id"
        case feedItemId = "feed_item_id"
        case chunkIndex = "chunk_index"
        case chunkText = "chunk_text"
        case confidence
    }

    init(
        id: Int64? = nil,
        edgeId: Int64,
        feedItemId: Int64,
        chunkIndex: Int? = nil,
        chunkText: String? = nil,
        confidence: Double? = nil
    ) {
        self.id = id
        self.edgeId = edgeId
        self.feedItemId = feedItemId
        self.chunkIndex = chunkIndex
        self.chunkText = chunkText
        self.confidence = confidence
    }
}
