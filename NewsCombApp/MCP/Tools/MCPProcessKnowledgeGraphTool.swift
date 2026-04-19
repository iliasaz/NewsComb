import Foundation
import MCP

/// Triggers the same action as the "Process Knowledge Graph" toolbar button:
/// runs LLM extraction over unprocessed articles, persists nodes/edges, and
/// auto-simplifies the graph at the end.
enum MCPProcessKnowledgeGraphTool {
    static func run(arguments: [String: Value]) async -> String {
        let wait = arguments["wait"]?.boolValue ?? false
        return await MCPAppCoordinator.shared.processKnowledgeGraph(wait: wait)
    }
}

/// Cancels a running knowledge graph processing job (mirrors the "Stop" button).
enum MCPCancelKnowledgeGraphProcessingTool {
    static func run(arguments: [String: Value]) async -> String {
        await MCPAppCoordinator.shared.cancelKnowledgeGraphProcessing()
    }
}
