import Foundation
import MCP

/// Promotes tentative children of a parent cluster to permanent sub-themes.
/// Mirrors the "Save Split" item in `ThemeDetailView`'s Actions menu.
enum MCPSaveSplitTool {
    static func run(arguments: [String: Value]) async -> String {
        guard let parentId = arguments["parent_cluster_id"]?.intValue else {
            return "Error: parent_cluster_id is required."
        }
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.saveSplit(parentClusterId: Int64(parentId), wait: wait)
    }
}
