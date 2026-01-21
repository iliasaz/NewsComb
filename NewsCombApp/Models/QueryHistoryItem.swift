import Foundation
import GRDB

/// A persisted query history item containing the question and answer details.
struct QueryHistoryItem: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    let query: String
    let answer: String
    let relatedNodesJson: String?
    let sourceArticlesJson: String?
    let createdAt: Date

    static let databaseTableName = "query_history"

    enum Columns: String, ColumnExpression {
        case id, query, answer
        case relatedNodesJson = "related_nodes_json"
        case sourceArticlesJson = "source_articles_json"
        case createdAt = "created_at"
    }

    enum CodingKeys: String, CodingKey {
        case id, query, answer
        case relatedNodesJson = "related_nodes_json"
        case sourceArticlesJson = "source_articles_json"
        case createdAt = "created_at"
    }

    init(
        id: Int64? = nil,
        query: String,
        answer: String,
        relatedNodesJson: String? = nil,
        sourceArticlesJson: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.answer = answer
        self.relatedNodesJson = relatedNodesJson
        self.sourceArticlesJson = sourceArticlesJson
        self.createdAt = createdAt
    }

    /// Creates a QueryHistoryItem from a GraphRAGResponse.
    init(from response: GraphRAGResponse) {
        self.id = nil
        self.query = response.query
        self.answer = response.answer
        self.relatedNodesJson = Self.encodeRelatedNodes(response.relatedNodes)
        self.sourceArticlesJson = Self.encodeSourceArticles(response.sourceArticles)
        self.createdAt = response.generatedAt
    }

    /// Converts this history item to a GraphRAGResponse for display.
    func toGraphRAGResponse() -> GraphRAGResponse {
        GraphRAGResponse(
            id: UUID(),
            query: query,
            answer: answer,
            relatedNodes: decodeRelatedNodes(),
            sourceArticles: decodeSourceArticles(),
            generatedAt: createdAt
        )
    }

    // MARK: - JSON Encoding/Decoding

    private static func encodeRelatedNodes(_ nodes: [GraphRAGResponse.RelatedNode]) -> String? {
        let encodableNodes = nodes.map { node in
            EncodableRelatedNode(
                id: node.id,
                nodeId: node.nodeId,
                label: node.label,
                nodeType: node.nodeType,
                distance: node.distance
            )
        }
        guard let data = try? JSONEncoder().encode(encodableNodes) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeSourceArticles(_ articles: [GraphRAGResponse.SourceArticle]) -> String? {
        let encodableArticles = articles.map { article in
            EncodableSourceArticle(
                id: article.id,
                title: article.title,
                link: article.link,
                pubDate: article.pubDate,
                relevantChunks: article.relevantChunks.map { chunk in
                    EncodableRelevantChunk(
                        id: chunk.id,
                        chunkIndex: chunk.chunkIndex,
                        content: chunk.content,
                        distance: chunk.distance
                    )
                }
            )
        }
        guard let data = try? JSONEncoder().encode(encodableArticles) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private func decodeRelatedNodes() -> [GraphRAGResponse.RelatedNode] {
        guard let json = relatedNodesJson,
              let data = json.data(using: .utf8),
              let nodes = try? JSONDecoder().decode([EncodableRelatedNode].self, from: data) else {
            return []
        }
        return nodes.map { node in
            GraphRAGResponse.RelatedNode(
                id: node.id,
                nodeId: node.nodeId,
                label: node.label,
                nodeType: node.nodeType,
                distance: node.distance
            )
        }
    }

    private func decodeSourceArticles() -> [GraphRAGResponse.SourceArticle] {
        guard let json = sourceArticlesJson,
              let data = json.data(using: .utf8),
              let articles = try? JSONDecoder().decode([EncodableSourceArticle].self, from: data) else {
            return []
        }
        return articles.map { article in
            GraphRAGResponse.SourceArticle(
                id: article.id,
                title: article.title,
                link: article.link,
                pubDate: article.pubDate,
                relevantChunks: article.relevantChunks.map { chunk in
                    GraphRAGResponse.RelevantChunk(
                        id: chunk.id,
                        chunkIndex: chunk.chunkIndex,
                        content: chunk.content,
                        distance: chunk.distance
                    )
                }
            )
        }
    }
}

// MARK: - Encodable Types for JSON Serialization

private struct EncodableRelatedNode: Codable {
    let id: Int64
    let nodeId: String
    let label: String
    let nodeType: String?
    let distance: Double
}

private struct EncodableSourceArticle: Codable {
    let id: Int64
    let title: String
    let link: String?
    let pubDate: Date?
    let relevantChunks: [EncodableRelevantChunk]
}

private struct EncodableRelevantChunk: Codable {
    let id: Int64
    let chunkIndex: Int
    let content: String
    let distance: Double
}
