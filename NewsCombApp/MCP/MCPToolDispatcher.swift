import Foundation
import MCP

/// Dispatches MCP tool calls to the appropriate handler.
/// All tools use the app's existing services via `Database.shared`.
enum MCPToolDispatcher {
    static func dispatch(
        toolName: String,
        arguments: [String: Value]
    ) async throws -> String {
        switch toolName {
        case "search_concepts":
            return try MCPSearchConceptsTool.run(arguments: arguments)
        case "search_chunks":
            return try MCPSearchChunksTool.run(arguments: arguments)
        case "get_node_neighbors":
            return try MCPGetNodeNeighborsTool.run(arguments: arguments)
        case "find_paths":
            return try MCPFindPathsTool.run(arguments: arguments)
        case "get_themes":
            return try MCPGetThemesTool.run(arguments: arguments)
        case "get_theme_details":
            return try MCPGetThemeDetailsTool.run(arguments: arguments)
        case "get_statistics":
            return try MCPGetStatisticsTool.run(arguments: arguments)
        case "get_recent_articles":
            return try MCPGetRecentArticlesTool.run(arguments: arguments)
        case "query_knowledge_graph":
            return try await MCPQueryKnowledgeGraphTool.run(arguments: arguments)
        default:
            throw MCPToolError(message: "Unknown tool: \(toolName)")
        }
    }
}
