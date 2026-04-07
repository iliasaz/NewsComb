import Foundation
import MCP
import OSLog

/// Dispatches MCP tool calls to the appropriate handler.
/// All tools use the app's existing services via `Database.shared`.
enum MCPToolDispatcher {

    private static let logger = Logger(subsystem: "com.newscomb.app", category: "MCPTools")

    static func dispatch(
        toolName: String,
        arguments: [String: Value]
    ) async throws -> String {
        let argsSummary = arguments.map { "\($0.key): \($0.value)" }.joined(separator: ", ")
        logger.info("→ \(toolName, privacy: .public)(\(argsSummary, privacy: .public))")

        let start = ContinuousClock.now

        do {
            let result: String
            switch toolName {
            case "search_concepts":
                result = try MCPSearchConceptsTool.run(arguments: arguments)
            case "search_chunks":
                result = try MCPSearchChunksTool.run(arguments: arguments)
            case "get_node_neighbors":
                result = try MCPGetNodeNeighborsTool.run(arguments: arguments)
            case "find_paths":
                result = try MCPFindPathsTool.run(arguments: arguments)
            case "get_themes":
                result = try MCPGetThemesTool.run(arguments: arguments)
            case "get_theme_details":
                result = try MCPGetThemeDetailsTool.run(arguments: arguments)
            case "get_statistics":
                result = try MCPGetStatisticsTool.run(arguments: arguments)
            case "get_recent_articles":
                result = try MCPGetRecentArticlesTool.run(arguments: arguments)
            case "query_knowledge_graph":
                result = try await MCPQueryKnowledgeGraphTool.run(arguments: arguments)
            default:
                throw MCPToolError(message: "Unknown tool: \(toolName)")
            }

            let elapsed = ContinuousClock.now - start
            let outputPreview = result.prefix(500)
            let truncated = result.count > 500 ? "… (\(result.count) chars)" : ""
            logger.info("← \(toolName, privacy: .public) [\(elapsed, privacy: .public)] \(outputPreview, privacy: .public)\(truncated, privacy: .public)")

            return result
        } catch {
            let elapsed = ContinuousClock.now - start
            logger.error("✗ \(toolName, privacy: .public) [\(elapsed, privacy: .public)] \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
