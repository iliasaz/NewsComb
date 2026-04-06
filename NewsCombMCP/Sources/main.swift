import Foundation
import MCP

// Locate the NewsComb database.
// Default: ~/Library/Application Support/NewsComb/newscomb.sqlite
// Override with NEWSCOMB_DB_PATH environment variable.
let dbPath: String
if let override = ProcessInfo.processInfo.environment["NEWSCOMB_DB_PATH"] {
    dbPath = override
} else {
    let appSupport = FileManager.default.urls(
        for: .applicationSupportDirectory, in: .userDomainMask
    ).first!
    let defaultPath = appSupport
        .appending(path: "NewsComb")
        .appending(path: "newscomb.sqlite")
        .path(percentEncoded: false)
    dbPath = defaultPath
}

guard FileManager.default.fileExists(atPath: dbPath) else {
    // Write to stderr so it doesn't interfere with stdio transport
    FileHandle.standardError.write(
        Data("Error: NewsComb database not found at \(dbPath)\n".utf8)
    )
    FileHandle.standardError.write(
        Data("Set NEWSCOMB_DB_PATH environment variable to the database path.\n".utf8)
    )
    exit(1)
}

// Initialize read-only database access
let database: ReadOnlyDatabase
do {
    database = try ReadOnlyDatabase(path: dbPath)
} catch {
    FileHandle.standardError.write(
        Data("Error: Failed to open database: \(error)\n".utf8)
    )
    exit(1)
}

// Create the MCP server
let server = Server(
    name: "newscomb",
    version: "1.0.0",
    instructions: """
        NewsComb Knowledge Intelligence Server

        This server provides access to a knowledge hypergraph built from RSS news feeds. \
        The hypergraph contains entities (nodes), relationships (hyperedges), article chunks, \
        embeddings, and story theme clusters extracted from news articles.

        ## Available capabilities:
        - **search_concepts**: Find entities/concepts in the knowledge graph using full-text search
        - **search_chunks**: Search article text chunks for specific content
        - **get_node_neighbors**: Explore the graph by finding relationships connected to a concept
        - **find_paths**: Discover multi-hop reasoning paths between two concepts
        - **get_themes**: Browse automatically discovered story themes/clusters
        - **get_theme_details**: Get detailed information about a specific theme
        - **get_statistics**: Get knowledge graph statistics (node/edge/article counts)
        - **get_recent_articles**: List recently ingested articles from RSS feeds

        ## Workflow tips:
        1. Start with search_concepts or get_themes to find relevant topics
        2. Use get_node_neighbors to explore connections around interesting concepts
        3. Use find_paths to discover causal chains between concepts
        4. Use search_chunks to find supporting evidence in article text
        """,
    capabilities: Server.Capabilities(
        tools: .init()
    )
)

// Register tool handlers
let toolHandler = ToolHandler(database: database)
await toolHandler.register(on: server)

// Start the server with stdio transport
let transport = StdioTransport()
try await server.start(transport: transport)

// Wait for the server to finish (blocks until stdin closes)
await server.waitUntilCompleted()
