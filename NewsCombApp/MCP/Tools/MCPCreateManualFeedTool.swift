import Foundation
import MCP

/// Creates a "manual" feed — an `rss_source` row with a synthetic URL that
/// the regular RSS refresh path skips. Acts as a container for articles
/// ingested via `ingest_article`.
enum MCPCreateManualFeedTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            throw MCPToolError.missingParameter("title")
        }
        return await MCPAppCoordinator.shared.createManualFeed(title: title)
    }
}
