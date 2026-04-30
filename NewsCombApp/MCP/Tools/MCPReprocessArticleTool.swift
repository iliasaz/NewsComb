import Foundation
import MCP

/// Drops one article's downstream knowledge-graph state — chunks, edges,
/// incidences, provenance, and any nodes orphaned by the edge deletion — and
/// re-runs per-article extraction in a single transaction-then-extract flow.
/// Use this after `ingest_article` has updated a body and the caller wants the
/// graph to reflect the new body immediately, instead of waiting for the next
/// batch `process_knowledge_graph` (which leaves the old edges and orphan
/// nodes behind because re-extraction generates new chunk-hashed edge IDs
/// that don't dedupe against the old ones).
enum MCPReprocessArticleTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let feedItemId = arguments["feed_item_id"]?.intValue.map(Int64.init) else {
            throw MCPToolError.missingParameter("feed_item_id")
        }
        return await MCPAppCoordinator.shared.reprocessArticle(feedItemId: feedItemId)
    }
}
