import Foundation
import MCP

/// Extracts events matching a free-text phrase from a parent cluster as a tentative
/// sub-theme. Mirrors the "Extract Theme by Phrase…" item in `ThemeDetailView`.
enum MCPExtractThemeTool {
    static func run(arguments: [String: Value]) async -> String {
        guard let parentId = arguments["parent_cluster_id"]?.intValue else {
            return "Error: parent_cluster_id is required."
        }
        guard let query = arguments["query"]?.stringValue, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Error: query is required and must be non-empty."
        }
        let topK = arguments["top_k"]?.intValue ?? 200
        let threshold = arguments["similarity_threshold"]?.doubleValue.map { Float($0) } ?? 0.45
        let relabel = arguments["relabel"]?.boolValue ?? true
        let dryRun = arguments["dry_run"]?.boolValue ?? false
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.extractTheme(
            parentClusterId: Int64(parentId),
            queryText: query,
            topK: topK,
            similarityThreshold: threshold,
            relabel: relabel,
            dryRun: dryRun,
            wait: wait
        )
    }
}
