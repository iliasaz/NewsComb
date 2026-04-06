# NewsComb MCP Server

An [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server that exposes NewsComb's knowledge intelligence features to AI assistants like Claude Code, Claude Work, and Codex.

Use the NewsComb app for the GUI experience — feed management, visual graph exploration, theme browsing — and the MCP server for agent-powered research workflows. Both run simultaneously in the same process, sharing all services.

## Architecture

The MCP server runs **inside the NewsComb app process** alongside the SwiftUI GUI. When the app launches, it starts a stdio MCP server on a background task. This means:

- **Zero code duplication** — the MCP tools use the same `NomicEmbeddingService.shared`, `HypergraphPathService`, `Database.shared`, and `ContextCollector` that the GUI uses
- **Shared Nomic model** — the 768-dim embedding model is loaded once and shared between the GUI's GraphRAG queries and MCP tool calls
- **Live data** — MCP tools always see the latest ingested articles, embeddings, and clusters
- **The app must be running** for the MCP server to be available

The MCP server source lives in `NewsCombApp/MCP/` within the main app target.

## Features

| Tool | Description |
|------|-------------|
| `query_knowledge_graph` | **Full RAG pipeline**: embeds question with on-device Nomic, vector search, BFS reasoning paths, context assembly — primary research tool |
| `search_concepts` | Full-text search for entities/concepts in the knowledge graph |
| `search_chunks` | Full-text search over article text chunks |
| `get_node_neighbors` | Explore relationships connected to a concept |
| `find_paths` | Discover multi-hop reasoning paths between concepts |
| `get_themes` | Browse story theme clusters from HDBSCAN clustering |
| `get_theme_details` | Detailed view of a theme: entities, relationships, exemplars |
| `get_statistics` | Knowledge graph statistics |
| `get_recent_articles` | List recently ingested articles from RSS feeds |

## Prerequisites

- macOS 26+ with Swift 6.2+ (Apple Silicon recommended for GPU-accelerated embeddings)
- The NewsComb app built and running (it manages RSS ingestion, knowledge extraction, and hosts the MCP server)
- The Nomic Embed Text v1.5 model is downloaded automatically from Hugging Face Hub on first use

## Setup

### 1. Build and run the NewsComb app

Open `NewsCombApp.xcodeproj` in Xcode and run the app. The MCP server starts automatically on launch.

### 2. Find the app binary path

The app binary is inside the built `.app` bundle. To find it:

```bash
# After building in Xcode (Debug):
find ~/Library/Developer/Xcode/DerivedData -name "NewsCombApp" -type f -path "*/Build/Products/Debug/*" 2>/dev/null | head -1
```

Or for a Release build, archive and export the app, then the binary is at:
```
/path/to/NewsCombApp.app/Contents/MacOS/NewsCombApp
```

### 3. Configure your MCP client

#### Claude Code

Create or edit `.mcp.json` in your project root:

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsCombApp.app/Contents/MacOS/NewsCombApp"
    }
  }
}
```

Or add to `~/.claude/settings.json` for global access across all projects.

#### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsCombApp.app/Contents/MacOS/NewsCombApp"
    }
  }
}
```

Restart Claude Desktop to pick up the new server.

### 4. Verify

After configuring, try:

> "What tools do you have from newscomb?"

> "Use query_knowledge_graph to tell me about recent AI chip developments"

## Example Workflows

### Research a topic (recommended)

Ask your AI assistant a question and it will call `query_knowledge_graph` automatically:

> "What are the connections between NVIDIA and the AI chip market?"

The tool runs the full RAG pipeline: keyword extraction → Nomic embedding → vector search → BFS reasoning paths → context assembly. The returned context includes related concepts, multi-hop reasoning paths, relationships with provenance, source text chunks, and source articles.

### Manual exploration

For more targeted research, the assistant can use the individual tools:

1. `search_concepts` — find entities ("NVIDIA", "AMD", "AI chips")
2. `get_node_neighbors` — explore what's connected to a concept
3. `find_paths` — discover causal chains between two specific concepts
4. `search_chunks` — find supporting evidence in article text

### Explore themes

1. `get_themes` — browse HDBSCAN-discovered story clusters
2. `get_theme_details` — drill into a specific theme's entities and relationships

### Monitor feeds

1. `get_statistics` — knowledge graph overview
2. `get_recent_articles` — latest ingested content

## Standalone Executable (Legacy)

The `NewsCombMCP/` directory contains a standalone SPM executable that was the original MCP server implementation. It duplicates app services (embedding, BFS, SQL queries) and is no longer the recommended approach. It may be removed in a future release.

## Dependencies

The MCP server uses these frameworks (all part of the main app):

- **GRDBCustom** — GRDB with **sqlite-vec** compiled in for `vec_distance_cosine()` vector similarity search
- **swift-embeddings** — on-device Nomic Embed Text v1.5 (768-dim) embeddings via Apple MLTensor/GPU
- **MCP Swift SDK** — Model Context Protocol server implementation with stdio transport
- **HyperGraphReasoning** — BFS path finding over the hypergraph
