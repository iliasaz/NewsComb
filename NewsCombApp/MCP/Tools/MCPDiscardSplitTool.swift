import Foundation
import MCP

/// Removes tentative children of a parent cluster.
/// Mirrors the "Discard Split" item in `ThemeDetailView`'s Actions menu.
enum MCPDiscardSplitTool {
    static func run(arguments: [String: Value]) async -> String {
        guard let parentId = arguments["parent_cluster_id"]?.intValue else {
            return "Error: parent_cluster_id is required."
        }
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.discardSplit(parentClusterId: Int64(parentId), wait: wait)
    }
}
