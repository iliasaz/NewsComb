import Foundation
import MCP

/// Triggers the same action as the "Recompute All" themes menu item:
/// runs the full PCA → UMAP → HDBSCAN clustering pipeline and persists new themes.
enum MCPRebuildThemesTool {
    static func run(arguments: [String: Value]) async -> String {
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.rebuildThemes(wait: wait)
    }
}

/// Triggers the same action as the "Regenerate Summaries" themes menu item:
/// re-runs the LLM labeling step on the existing clusters without re-clustering.
enum MCPRegenerateThemeSummariesTool {
    static func run(arguments: [String: Value]) async -> String {
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.regenerateThemeSummaries(wait: wait)
    }
}
