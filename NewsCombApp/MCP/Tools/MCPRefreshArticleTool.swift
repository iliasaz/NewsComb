import Foundation
import MCP

/// Re-fetches an individual article's `full_content` from its `link` via the
/// same Postlight extraction pipeline the RSS path uses, independently of
/// any feed-level refresh.
enum MCPRefreshArticleTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let feedItemId = arguments["feed_item_id"]?.intValue.map(Int64.init) else {
            throw MCPToolError.missingParameter("feed_item_id")
        }
        return await MCPAppCoordinator.shared.refreshArticle(feedItemId: feedItemId)
    }
}
