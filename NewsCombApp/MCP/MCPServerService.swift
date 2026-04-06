import Foundation
import MCP
import OSLog

/// Manages the MCP (Model Context Protocol) HTTP server within the app process.
///
/// Starts an HTTP server on localhost that AI assistants (Claude Code, Claude Desktop)
/// connect to via a lightweight stdio bridge. The bridge translates stdio ↔ HTTP,
/// following the same pattern as Xcode's `mcpbridge`.
///
/// Architecture:
/// ```
/// Claude Code ←stdio→ newscomb-mcp-bridge ←HTTP→ NewsCombApp (localhost:63548)
/// ```
final class MCPServerService: Sendable {

    static let shared = MCPServerService()

    private let logger = Logger(subsystem: "com.newscomb.app", category: "MCPServer")

    private init() {}

    /// Starts the MCP HTTP server.
    /// The server listens on localhost:63548 for HTTP POST requests from the bridge CLI.
    func start() {
        Task.detached {
            await self.runServer()
        }
    }

    @concurrent
    private func runServer() async {
        logger.info("Starting MCP HTTP server")

        do {
            let httpServer = try MCPHTTPServer(serverFactory: { transport in
                await self.createServer(transport: transport)
            })
            httpServer.start()
            logger.info("MCP HTTP server ready on http://127.0.0.1:\(MCPHTTPServer.defaultPort, privacy: .public)")

            // Keep alive — the HTTP server runs until the app exits.
            // NWListener is retained by `httpServer`; sleep forever to keep it alive.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(86400))
            }
        } catch {
            logger.error("MCP HTTP server failed to start: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Creates a new MCP Server instance with all tools registered.
    /// Called by MCPHTTPServer for each new client session.
    private func createServer(transport: StatelessHTTPServerTransport) async -> Server {
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

        let toolHandler = MCPToolHandler()
        await toolHandler.register(on: server)

        return server
    }
}
