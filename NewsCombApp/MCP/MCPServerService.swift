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

                ## Research (read-only):
                - **query_knowledge_graph**: Full RAG pipeline — embed question with Nomic, vector search, \
                BFS reasoning paths, context assembly. Use this as your primary research tool.
                - **search_concepts**: Find entities/concepts in the knowledge graph using full-text search
                - **search_chunks**: Search article text chunks for specific content
                - **get_node_neighbors**: Explore the graph by finding relationships connected to a concept
                - **find_paths**: Discover multi-hop reasoning paths between two concepts
                - **get_statistics**: Get knowledge graph statistics (node/edge/article counts)
                - **get_recent_articles**: List recently ingested articles from RSS feeds

                ## Theme exploration (read-only):
                - **get_themes**: Browse automatically discovered story themes/clusters
                - **get_theme_details**: Top-10 exemplar events plus entities and families for a theme
                - **get_theme_provenance**: All members of a theme with article + chunk-level provenance
                - **get_entity_themes**: Themes an entity participates in, ranked by edge count
                - **compare_themes**: Centroid cosine, top-entity Jaccard, and shared-article overlap between themes
                - **find_articles_across_themes**: Hub articles spanning multiple themes

                ## App actions (mirror UI buttons — affect the running app):
                - **refresh_feeds**: Same as the Refresh toolbar button — fetch every RSS source.
                - **process_knowledge_graph**: Same as the Process Knowledge Graph button — extract entities/edges from new articles.
                - **cancel_knowledge_graph_processing**: Same as the Stop button shown while processing.
                - **rebuild_themes**: Same as the Recompute All themes menu — full clustering pipeline.
                - **regenerate_theme_summaries**: Same as Regenerate Summaries — re-label without re-clustering.
                - **get_app_status**: Snapshot of every long-running operation; poll this after firing background actions.

                ## Workflow tips:
                1. For research questions, start with query_knowledge_graph — it runs the full RAG pipeline.
                2. Before research, consider refresh_feeds + process_knowledge_graph (with wait=true) to ensure data is current.
                3. After major ingestion, run rebuild_themes to refresh story clusters before theme analysis.
                4. Use get_themes → get_theme_provenance for deep-dives into a specific story.
                5. Use get_entity_themes to see how a single actor maps onto your knowledge graph's narratives.
                6. For long-running actions (process/rebuild), pass wait=false and poll get_app_status.
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
