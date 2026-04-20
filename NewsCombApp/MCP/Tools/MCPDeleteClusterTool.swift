import Foundation
import MCP

/// Deletes a cluster row. Underlying graph data (nodes, edges, embeddings, chunks,
/// articles) is preserved. Saved children of a parent get unlinked (their
/// `parent_cluster_id` becomes NULL); tentative children are deleted.
/// Mirrors the "Delete Cluster" item in `ThemeDetailView`'s Actions menu.
enum MCPDeleteClusterTool {
    static func run(arguments: [String: Value]) async -> String {
        guard let clusterId = arguments["cluster_id"]?.intValue else {
            return "Error: cluster_id is required."
        }
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.deleteCluster(clusterId: Int64(clusterId), wait: wait)
    }
}
