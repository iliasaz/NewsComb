import Foundation
import MCP

/// Re-clusters a single existing theme to surface its sub-structure.
/// Mirrors the "Split" menu in `ThemeDetailView`.
enum MCPSplitClusterTool {
    static func run(arguments: [String: Value]) async -> String {
        guard let clusterId = arguments["cluster_id"]?.intValue else {
            return "Error: cluster_id is required."
        }
        let minClusterSize = arguments["min_cluster_size"]?.intValue
        let minSamples = arguments["min_samples"]?.intValue
        let relabel = arguments["relabel"]?.boolValue ?? true
        let dryRun = arguments["dry_run"]?.boolValue ?? false
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.splitCluster(
            clusterId: Int64(clusterId),
            minClusterSize: minClusterSize,
            minSamples: minSamples,
            relabel: relabel,
            dryRun: dryRun,
            wait: wait
        )
    }
}
