import Foundation
import MCP

/// Dispatches MCP tool calls to the appropriate query handler.
enum ToolDispatcher {
    static func dispatch(
        toolName: String,
        arguments: [String: Value],
        database: ReadOnlyDatabase
    ) throws -> String {
        switch toolName {
        case "search_concepts":
            return try SearchConceptsTool.run(arguments: arguments, database: database)
        case "search_chunks":
            return try SearchChunksTool.run(arguments: arguments, database: database)
        case "get_node_neighbors":
            return try GetNodeNeighborsTool.run(arguments: arguments, database: database)
        case "find_paths":
            return try FindPathsTool.run(arguments: arguments, database: database)
        case "get_themes":
            return try GetThemesTool.run(arguments: arguments, database: database)
        case "get_theme_details":
            return try GetThemeDetailsTool.run(arguments: arguments, database: database)
        case "get_statistics":
            return try GetStatisticsTool.run(arguments: arguments, database: database)
        case "get_recent_articles":
            return try GetRecentArticlesTool.run(arguments: arguments, database: database)
        default:
            throw ToolError(message: "Unknown tool: \(toolName)")
        }
    }
}
