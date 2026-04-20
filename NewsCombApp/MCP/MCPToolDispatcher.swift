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
            case "refresh_feeds":
                result = await MCPRefreshFeedsTool.run(arguments: arguments)
            case "process_knowledge_graph":
                result = await MCPProcessKnowledgeGraphTool.run(arguments: arguments)
            case "cancel_knowledge_graph_processing":
                result = await MCPCancelKnowledgeGraphProcessingTool.run(arguments: arguments)
            case "rebuild_themes":
                result = await MCPRebuildThemesTool.run(arguments: arguments)
            case "regenerate_theme_summaries":
                result = await MCPRegenerateThemeSummariesTool.run(arguments: arguments)
            case "split_cluster":
                result = await MCPSplitClusterTool.run(arguments: arguments)
            case "save_split":
                result = await MCPSaveSplitTool.run(arguments: arguments)
            case "discard_split":
                result = await MCPDiscardSplitTool.run(arguments: arguments)
            case "delete_cluster":
                result = await MCPDeleteClusterTool.run(arguments: arguments)
            case "identify_noise_pools":
                result = await MCPIdentifyNoisePoolsTool.run(arguments: arguments)
            case "drop_noise_pools":
                result = await MCPDropNoisePoolsTool.run(arguments: arguments)
            case "extract_theme":
                result = await MCPExtractThemeTool.run(arguments: arguments)
            case "get_app_status":
                result = await MCPGetAppStatusTool.run(arguments: arguments)
            case "get_theme_provenance":
                result = try MCPGetThemeProvenanceTool.run(arguments: arguments)
            case "compare_themes":
                result = try MCPCompareThemesTool.run(arguments: arguments)
            case "get_entity_themes":
                result = try MCPGetEntityThemesTool.run(arguments: arguments)
            case "find_articles_across_themes":
                result = try MCPFindArticlesAcrossThemesTool.run(arguments: arguments)
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
