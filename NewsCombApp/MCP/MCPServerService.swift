import Foundation
import MCP
import OSLog

/// Manages the MCP (Model Context Protocol) stdio server within the app process.
///
/// Starts automatically when the app launches, providing AI assistants (Claude Code,
/// Claude Desktop, etc.) with read access to the knowledge graph via stdio transport.
/// Reuses all existing app services — no code duplication.
final class MCPServerService: Sendable {

    static let shared = MCPServerService()

    private let logger = Logger(subsystem: "com.newscomb.app", category: "MCPServer")

    private init() {}

    /// Starts the MCP server on a background task.
    /// The server reads stdin and writes stdout using the MCP protocol.
    /// It runs until stdin closes (i.e., the MCP client disconnects).
    func start() {
        Task.detached {
            await self.runServer()
        }
    }

    @concurrent
    private func runServer() async {
        logger.info("Starting MCP stdio server")

        let server = Server(
            name: "newscomb",
            version: "1.0.0",
            instructions: """
                NewsComb Knowledge Intelligence Server

                This server provides access to a knowledge hypergraph built from RSS news feeds. \
                The hypergraph contains entities (nodes), relationships (hyperedges), article chunks, \
                embeddings, and story theme clusters extracted from news articles.

                ## Available capabilities:
                - **query_knowledge_graph**: Full RAG pipeline — embed question with Nomic, vector search, \
                BFS reasoning paths, context assembly. Use this as your primary research tool.
                - **search_concepts**: Find entities/concepts in the knowledge graph using full-text search
                - **search_chunks**: Search article text chunks for specific content
                - **get_node_neighbors**: Explore the graph by finding relationships connected to a concept
                - **find_paths**: Discover multi-hop reasoning paths between two concepts
                - **get_themes**: Browse automatically discovered story themes/clusters
                - **get_theme_details**: Get detailed information about a specific theme
                - **get_statistics**: Get knowledge graph statistics (node/edge/article counts)
                - **get_recent_articles**: List recently ingested articles from RSS feeds

                ## Workflow tips:
                1. For research questions, start with query_knowledge_graph — it runs the full RAG pipeline
                2. Use search_concepts or get_themes for exploratory browsing
                3. Use get_node_neighbors to explore connections around interesting concepts
                4. Use find_paths to discover causal chains between two specific concepts
                5. Use search_chunks to find supporting evidence in article text
                """,
            capabilities: Server.Capabilities(
                tools: .init()
            )
        )

        // Register tool handlers
        let toolHandler = MCPToolHandler()
        await toolHandler.register(on: server)

        // Start stdio transport
        let transport = StdioTransport()
        do {
            try await server.start(transport: transport)
            logger.info("MCP server started successfully on stdio")
            await server.waitUntilCompleted()
            logger.info("MCP server stopped (client disconnected)")
        } catch {
            logger.error("MCP server failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
