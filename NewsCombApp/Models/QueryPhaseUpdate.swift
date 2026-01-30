import Foundation

/// Represents an incremental update from the GraphRAG query pipeline.
///
/// Each case corresponds to a pipeline phase, allowing consumers
/// to progressively display results as they become available.
enum QueryPhaseUpdate: Sendable {
    /// A human-readable status message describing the current pipeline phase.
    case status(String)

    /// Keywords extracted from the user's question.
    case keywords([String])

    /// Nodes in the knowledge graph related to the query.
    case relatedNodes([GraphRAGResponse.RelatedNode])

    /// Multi-hop reasoning paths discovered between related concepts.
    case reasoningPaths([GraphRAGResponse.ReasoningPath])

    /// Supporting graph relationships (edges with source/target nodes).
    case graphPaths([GraphRAGResponse.GraphPath])

    /// A single token from the streaming LLM answer generation.
    case answerToken(String)

    /// Source articles that provided context for the answer.
    case sourceArticles([GraphRAGResponse.SourceArticle])

    /// The pipeline completed successfully with the full assembled response.
    case completed(GraphRAGResponse)

    /// The pipeline encountered an error.
    case failed(Error)
}
