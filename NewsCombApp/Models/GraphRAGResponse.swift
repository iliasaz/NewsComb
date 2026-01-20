import Foundation

/// Response from a GraphRAG query over the knowledge graph.
struct GraphRAGResponse: Identifiable, Sendable {
    let id: UUID
    let query: String
    let answer: String
    let relatedNodes: [RelatedNode]
    let sourceArticles: [SourceArticle]
    let generatedAt: Date

    init(
        id: UUID = UUID(),
        query: String,
        answer: String,
        relatedNodes: [RelatedNode] = [],
        sourceArticles: [SourceArticle] = [],
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.answer = answer
        self.relatedNodes = relatedNodes
        self.sourceArticles = sourceArticles
        self.generatedAt = generatedAt
    }

    /// A node related to the query with its similarity score.
    struct RelatedNode: Identifiable, Sendable {
        let id: Int64
        let nodeId: String
        let label: String
        let nodeType: String?
        let distance: Double

        /// Similarity score derived from distance (0-1, higher is more similar).
        var similarity: Double {
            // Convert L2 distance to similarity (assuming normalized vectors)
            max(0, 1 - distance / 2)
        }
    }

    /// An article that provided context for the answer.
    struct SourceArticle: Identifiable, Sendable {
        let id: Int64
        let title: String
        let link: String?
        let pubDate: Date?
        let relevantChunks: [RelevantChunk]
    }

    /// A chunk of text from an article relevant to the query.
    struct RelevantChunk: Identifiable, Sendable {
        let id: Int64
        let chunkIndex: Int
        let content: String
        let distance: Double

        var similarity: Double {
            max(0, 1 - distance / 2)
        }
    }
}

/// Context gathered from the knowledge graph for answering a query.
struct GraphRAGContext: Sendable {
    let relevantNodes: [GraphRAGResponse.RelatedNode]
    let relevantEdges: [ContextEdge]
    let relevantChunks: [ChunkWithArticle]

    /// An edge with its connected nodes for context.
    struct ContextEdge: Sendable {
        let edgeId: Int64
        let relation: String
        let sourceNodes: [String]
        let targetNodes: [String]
        let chunkText: String?
    }

    /// A chunk with its parent article information.
    struct ChunkWithArticle: Sendable {
        let chunkId: Int64
        let chunkIndex: Int
        let content: String
        let distance: Double
        let articleId: Int64
        let articleTitle: String
    }

    /// Formats the context into a string for LLM consumption.
    func formatForLLM() -> String {
        var parts: [String] = []

        // Add relevant concepts/entities
        if !relevantNodes.isEmpty {
            let nodesList = relevantNodes.prefix(10).map { node in
                "- \(node.label)" + (node.nodeType.map { " (\($0))" } ?? "")
            }.joined(separator: "\n")
            parts.append("## Relevant Concepts\n\(nodesList)")
        }

        // Add relationships
        if !relevantEdges.isEmpty {
            let edgesList = relevantEdges.prefix(15).map { edge in
                let sources = edge.sourceNodes.joined(separator: ", ")
                let targets = edge.targetNodes.joined(separator: ", ")
                return "- \(sources) --[\(edge.relation)]--> \(targets)"
            }.joined(separator: "\n")
            parts.append("## Relationships\n\(edgesList)")
        }

        // Add source chunks for context
        if !relevantChunks.isEmpty {
            let chunksList = relevantChunks.prefix(5).map { chunk in
                "### From: \(chunk.articleTitle)\n\(chunk.content)"
            }.joined(separator: "\n\n")
            parts.append("## Source Content\n\(chunksList)")
        }

        return parts.joined(separator: "\n\n")
    }
}
