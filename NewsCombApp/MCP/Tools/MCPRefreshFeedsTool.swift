import Foundation
import MCP

/// Triggers the same action as the "Refresh" toolbar button in the NewsComb UI:
/// fetches every RSS source, extracts content, and updates the metrics shown in the app.
enum MCPRefreshFeedsTool {
    static func run(arguments: [String: Value]) async -> String {
        let wait = arguments["wait"]?.boolValue ?? true
        return await MCPAppCoordinator.shared.refreshFeeds(wait: wait)
    }
}
