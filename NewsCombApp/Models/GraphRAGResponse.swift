import Foundation

/// Response from a GraphRAG query over the knowledge graph.
struct GraphRAGResponse: Identifiable, Sendable {
    let id: UUID
    let query: String
    let answer: String
    let relatedNodes: [RelatedNode]
    let reasoningPaths: [ReasoningPath]
    let graphPaths: [GraphPath]
    let sourceArticles: [SourceArticle]
    let generatedAt: Date

    init(
        id: UUID = UUID(),
        query: String,
        answer: String,
        relatedNodes: [RelatedNode] = [],
        reasoningPaths: [ReasoningPath] = [],
        graphPaths: [GraphPath] = [],
        sourceArticles: [SourceArticle] = [],
        generatedAt: Date = Date()
    ) {
        self.id = id
        self.query = query
        self.answer = answer
        self.relatedNodes = relatedNodes
        self.reasoningPaths = reasoningPaths
        self.graphPaths = graphPaths
        self.sourceArticles = sourceArticles
        self.generatedAt = generatedAt
    }

    /// A multi-hop reasoning path showing how concepts connect through the graph.
    struct ReasoningPath: Identifiable, Sendable {
        let id: UUID
        let sourceConcept: String
        let targetConcept: String
        let intermediateNodes: [String]
        let edgeCount: Int

        init(
            id: UUID = UUID(),
            sourceConcept: String,
            targetConcept: String,
            intermediateNodes: [String] = [],
            edgeCount: Int
        ) {
            self.id = id
            self.sourceConcept = sourceConcept
            self.targetConcept = targetConcept
            self.intermediateNodes = intermediateNodes
            self.edgeCount = edgeCount
        }

        /// Natural language description of the path.
        var description: String {
            if intermediateNodes.isEmpty {
                return "\(sourceConcept) connects directly to \(targetConcept)"
            } else {
                let intermediates = intermediateNodes.joined(separator: " → ")
                return "\(sourceConcept) → \(intermediates) → \(targetConcept)"
            }
        }

        /// Whether this is a multi-hop path (more than 1 edge).
        var isMultiHop: Bool {
            edgeCount > 1
        }
    }

    /// A path/relationship in the knowledge graph used for reasoning.
    struct GraphPath: Identifiable, Sendable {
        let id: Int64
        let relation: String
        let sourceNodes: [String]
        let targetNodes: [String]
        let provenanceText: String?

        init(
            id: Int64,
            relation: String,
            sourceNodes: [String],
            targetNodes: [String],
            provenanceText: String? = nil
        ) {
            self.id = id
            self.relation = relation
            self.sourceNodes = sourceNodes
            self.targetNodes = targetNodes
            self.provenanceText = provenanceText
        }

        /// Natural language sentence describing the relationship.
        var naturalLanguageSentence: String {
            let sources = sourceNodes.joined(separator: ", ")
            let targets = targetNodes.joined(separator: ", ")
            let verb = formatRelationAsVerb(relation)

            if targets.isEmpty {
                return "\(sources) \(verb)."
            }
            return "\(sources) \(verb) \(targets)."
        }

        /// Formatted display string for the path (arrow notation).
        var displayText: String {
            let sources = sourceNodes.joined(separator: ", ")
            let targets = targetNodes.joined(separator: ", ")
            let formattedRelation = formatRelationAsTitle(relation)
            return "\(sources) → \(formattedRelation) → \(targets)"
        }

        /// Formats a relation string as a verb phrase (e.g., "partnered_with" → "partnered with").
        private func formatRelationAsVerb(_ relation: String) -> String {
            relation
                .replacing("_", with: " ")
                .lowercased()
        }

        /// Formats a relation string as a title (e.g., "partnered_with" → "Partnered With").
        private func formatRelationAsTitle(_ relation: String) -> String {
            relation
                .replacing("_", with: " ")
                .split(separator: " ")
                .map { $0.prefix(1).uppercased() + $0.dropFirst().lowercased() }
                .joined(separator: " ")
        }
    }

    /// A node related to the query with its similarity score.
    struct RelatedNode: Identifiable, Sendable {
        let id: Int64
        let nodeId: String
        let label: String
        let nodeType: String?
        let distance: Double

        /// Similarity score derived from cosine distance (0-1, higher is more similar).
        /// Cosine distance = 1 - cosine_similarity, so similarity = 1 - distance.
        var similarity: Double {
            max(0, min(1, 1 - distance))
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

        /// Similarity score derived from cosine distance (0-1, higher is more similar).
        var similarity: Double {
            max(0, min(1, 1 - distance))
        }
    }
}

/// Context gathered from the knowledge graph for answering a query.
struct GraphRAGContext: Sendable {
    let relevantNodes: [GraphRAGResponse.RelatedNode]
    let relevantEdges: [ContextEdge]
    let relevantChunks: [ChunkWithArticle]
    let reasoningPaths: [ReasoningPath]

    init(
        relevantNodes: [GraphRAGResponse.RelatedNode],
        relevantEdges: [ContextEdge],
        relevantChunks: [ChunkWithArticle],
        reasoningPaths: [ReasoningPath] = []
    ) {
        self.relevantNodes = relevantNodes
        self.relevantEdges = relevantEdges
        self.relevantChunks = relevantChunks
        self.reasoningPaths = reasoningPaths
    }

    /// A reasoning path showing how concepts connect through the hypergraph.
    struct ReasoningPath: Sendable {
        let sourceConcept: String
        let targetConcept: String
        let intermediateNodes: [String]
        let edgeCount: Int
    }

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

        // Add reasoning paths (structured connections between concepts)
        if !reasoningPaths.isEmpty {
            let pathsList = reasoningPaths.prefix(5).map { path in
                formatReasoningPath(path)
            }.joined(separator: "\n")
            parts.append("## Reasoning Paths\n\(pathsList)")
        }

        // Add relationships
        if !relevantEdges.isEmpty {
            let edgesList = relevantEdges.prefix(15).map { edge in
                formatEdge(edge)
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

    /// Formats a reasoning path as a readable string showing how concepts connect.
    private func formatReasoningPath(_ path: ReasoningPath) -> String {
        if path.intermediateNodes.isEmpty {
            return "- \(path.sourceConcept) connects to \(path.targetConcept)"
        }

        // Build the path string showing intermediate connections
        var pathParts: [String] = [path.sourceConcept]
        for node in path.intermediateNodes {
            pathParts.append("(via \(node))")
        }
        pathParts.append(path.targetConcept)

        return "- " + pathParts.joined(separator: " → ")
    }

    /// Formats an edge as a natural language relationship.
    private func formatEdge(_ edge: ContextEdge) -> String {
        let sources = edge.sourceNodes.joined(separator: ", ")
        let targets = edge.targetNodes.joined(separator: ", ")
        let relation = edge.relation
            .replacing("_", with: " ")
            .replacing("path edge", with: "relates to")

        if targets.isEmpty {
            return "- \(sources) (\(relation))"
        }
        return "- \(sources) \(relation) \(targets)"
    }
}
