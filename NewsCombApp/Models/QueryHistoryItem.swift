import Foundation
import GRDB

/// A persisted query history item containing the question and answer details.
struct QueryHistoryItem: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord, Sendable {
    var id: Int64?
    let query: String
    let answer: String
    let relatedNodesJson: String?
    let reasoningPathsJson: String?
    let graphPathsJson: String?
    let sourceArticlesJson: String?
    var deepAnalysisJson: String?  // Legacy - kept for backwards compatibility
    var synthesizedAnalysis: String?
    var hypotheses: String?
    var analyzedAt: Date?
    let createdAt: Date

    static let databaseTableName = "query_history"

    enum Columns: String, ColumnExpression {
        case id, query, answer
        case relatedNodesJson = "related_nodes_json"
        case reasoningPathsJson = "reasoning_paths_json"
        case graphPathsJson = "graph_paths_json"
        case sourceArticlesJson = "source_articles_json"
        case deepAnalysisJson = "deep_analysis_json"
        case synthesizedAnalysis = "synthesized_analysis"
        case hypotheses
        case analyzedAt = "analyzed_at"
        case createdAt = "created_at"
    }

    enum CodingKeys: String, CodingKey {
        case id, query, answer
        case relatedNodesJson = "related_nodes_json"
        case reasoningPathsJson = "reasoning_paths_json"
        case graphPathsJson = "graph_paths_json"
        case sourceArticlesJson = "source_articles_json"
        case deepAnalysisJson = "deep_analysis_json"
        case synthesizedAnalysis = "synthesized_analysis"
        case hypotheses
        case analyzedAt = "analyzed_at"
        case createdAt = "created_at"
    }

    init(
        id: Int64? = nil,
        query: String,
        answer: String,
        relatedNodesJson: String? = nil,
        reasoningPathsJson: String? = nil,
        graphPathsJson: String? = nil,
        sourceArticlesJson: String? = nil,
        deepAnalysisJson: String? = nil,
        synthesizedAnalysis: String? = nil,
        hypotheses: String? = nil,
        analyzedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.answer = answer
        self.relatedNodesJson = relatedNodesJson
        self.reasoningPathsJson = reasoningPathsJson
        self.graphPathsJson = graphPathsJson
        self.sourceArticlesJson = sourceArticlesJson
        self.deepAnalysisJson = deepAnalysisJson
        self.synthesizedAnalysis = synthesizedAnalysis
        self.hypotheses = hypotheses
        self.analyzedAt = analyzedAt
        self.createdAt = createdAt
    }

    /// Creates a QueryHistoryItem from a GraphRAGResponse.
    init(from response: GraphRAGResponse) {
        self.id = nil
        self.query = response.query
        self.answer = response.answer
        self.relatedNodesJson = Self.encodeRelatedNodes(response.relatedNodes)
        self.reasoningPathsJson = Self.encodeReasoningPaths(response.reasoningPaths)
        self.graphPathsJson = Self.encodeGraphPaths(response.graphPaths)
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
            reasoningPaths: decodeReasoningPaths(),
            graphPaths: decodeGraphPaths(),
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

    private static func encodeReasoningPaths(_ paths: [GraphRAGResponse.ReasoningPath]) -> String? {
        let encodablePaths = paths.map { path in
            EncodableReasoningPath(
                sourceConcept: path.sourceConcept,
                targetConcept: path.targetConcept,
                intermediateNodes: path.intermediateNodes,
                edgeCount: path.edgeCount
            )
        }
        guard let data = try? JSONEncoder().encode(encodablePaths) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func encodeGraphPaths(_ paths: [GraphRAGResponse.GraphPath]) -> String? {
        let encodablePaths = paths.map { path in
            EncodableGraphPath(
                id: path.id,
                relation: path.relation,
                sourceNodes: path.sourceNodes,
                targetNodes: path.targetNodes,
                provenanceText: path.provenanceText
            )
        }
        guard let data = try? JSONEncoder().encode(encodablePaths) else { return nil }
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

    private func decodeReasoningPaths() -> [GraphRAGResponse.ReasoningPath] {
        guard let json = reasoningPathsJson,
              let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([EncodableReasoningPath].self, from: data) else {
            return []
        }
        return paths.map { path in
            GraphRAGResponse.ReasoningPath(
                sourceConcept: path.sourceConcept,
                targetConcept: path.targetConcept,
                intermediateNodes: path.intermediateNodes,
                edgeCount: path.edgeCount
            )
        }
    }

    private func decodeGraphPaths() -> [GraphRAGResponse.GraphPath] {
        guard let json = graphPathsJson,
              let data = json.data(using: .utf8),
              let paths = try? JSONDecoder().decode([EncodableGraphPath].self, from: data) else {
            return []
        }
        return paths.map { path in
            GraphRAGResponse.GraphPath(
                id: path.id,
                relation: path.relation,
                sourceNodes: path.sourceNodes,
                targetNodes: path.targetNodes,
                provenanceText: path.provenanceText
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

    // MARK: - Deep Analysis

    /// Whether this item has deep analysis results.
    var hasDeepAnalysis: Bool {
        synthesizedAnalysis != nil || hypotheses != nil
    }

    /// Converts the stored deep analysis fields to a DeepAnalysisResult.
    func toDeepAnalysisResult() -> DeepAnalysisResult? {
        // First try the new separate columns
        if let synthesis = synthesizedAnalysis, let hypo = hypotheses {
            return DeepAnalysisResult(
                synthesizedAnswer: synthesis,
                hypotheses: hypo,
                analyzedAt: analyzedAt ?? createdAt
            )
        }

        // Fall back to legacy JSON column for backwards compatibility
        guard let json = deepAnalysisJson,
              let data = json.data(using: .utf8),
              let result = try? JSONDecoder().decode(DeepAnalysisResult.self, from: data) else {
            return nil
        }
        return result
    }

    /// Returns a copy with the deep analysis result set.
    func withDeepAnalysis(_ result: DeepAnalysisResult) -> QueryHistoryItem {
        var copy = self
        copy.synthesizedAnalysis = result.synthesizedAnswer
        copy.hypotheses = result.hypotheses
        copy.analyzedAt = result.analyzedAt
        return copy
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

private struct EncodableGraphPath: Codable {
    let id: Int64
    let relation: String
    let sourceNodes: [String]
    let targetNodes: [String]
    let provenanceText: String?
}

private struct EncodableReasoningPath: Codable {
    let sourceConcept: String
    let targetConcept: String
    let intermediateNodes: [String]
    let edgeCount: Int
}
