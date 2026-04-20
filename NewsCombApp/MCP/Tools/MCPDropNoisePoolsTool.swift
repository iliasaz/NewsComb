import Foundation
import MCP

/// Drops the named noise-pool clusters (or all currently-flagged ones if no
/// `cluster_ids` are provided). Mirrors the toolbar action in `ThemesView`.
enum MCPDropNoisePoolsTool {
    static func run(arguments: [String: Value]) async -> String {
        let clusterIds: [Int64]?
        if let ids = arguments["cluster_ids"]?.arrayValue {
            clusterIds = ids.compactMap { $0.intValue.map { Int64($0) } }
        } else {
            clusterIds = nil
        }
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.dropNoisePools(ids: clusterIds, wait: wait)
    }
}
