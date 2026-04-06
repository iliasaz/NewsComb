# NewsComb MCP Server

An [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server that exposes NewsComb's knowledge intelligence features to AI assistants like Claude Code, Claude Work, and Codex.

Use the NewsComb app for the GUI experience — feed management, visual graph exploration, theme browsing — and the MCP server for agent-powered research workflows. Both run simultaneously, sharing the same knowledge graph.

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
- **The NewsComb app must be running** — it manages RSS ingestion, knowledge extraction, and keeps the database up to date. Launch the app first, then connect your MCP client.
- The Nomic Embed Text v1.5 model is downloaded automatically from Hugging Face Hub on first use of `query_knowledge_graph`

## Quick Start

### 1. Build the server

```bash
cd /path/to/NewsComb/NewsCombMCP
swift build -c release
```

The binary is at `.build/release/newscomb-mcp`.

### 2. Launch the NewsComb app

Open NewsComb.app and ensure your feeds are ingested and knowledge extraction has run. The MCP server reads the same database the app writes to.

### 3. Configure your MCP client

#### Claude Code

Create or edit `.mcp.json` in your project root (recommended for project-scoped access):

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsComb/NewsCombMCP/.build/release/newscomb-mcp"
    }
  }
}
```

Or add to `~/.claude/settings.json` for global access across all projects.

If your database is in a non-default location:

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsComb/NewsCombMCP/.build/release/newscomb-mcp",
      "env": {
        "NEWSCOMB_DB_PATH": "/path/to/newscomb.sqlite"
      }
    }
  }
}
```

#### Claude Desktop

Add to `~/Library/Application Support/Claude/claude_desktop_config.json`:

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsComb/NewsCombMCP/.build/release/newscomb-mcp"
    }
  }
}
```

Restart Claude Desktop to pick up the new server.

### 4. Verify

After restarting your MCP client, the tools should appear automatically. Try:

> "What tools do you have from newscomb?"

> "Use query_knowledge_graph to tell me about recent AI chip developments"

## Database Location

The server automatically looks for the database at:
```
~/Library/Application Support/NewsComb/newscomb.sqlite
```

This is the default location used by the NewsComb app. The server opens it in **read-only** mode, so it runs safely alongside the app with no risk of conflicts. Override with `NEWSCOMB_DB_PATH` if needed.

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

## Architecture

The MCP server is currently a **standalone CLI executable** that communicates via stdio transport. It reads the same SQLite database that the NewsComb app writes to.

### Current design

The server reimplements some app components (embedding service, BFS path finding, SQL queries) to operate independently. This means the Nomic model is loaded separately in the MCP process.

### Future direction

The plan is to move the MCP server into the main app process itself — the app would host a stdio MCP server alongside its SwiftUI GUI, similar to how Xcode exposes MCP tools. This eliminates all code duplication and lets the MCP server use the app's services directly (shared Nomic model, `GraphRAGService`, `HypergraphPathService`, etc.). A command-line flag (e.g., `--mcp-stdio`) would let MCP clients launch the app in headless server mode when it isn't already running.

### Dependencies

- **GRDBCustom** — GRDB with **sqlite-vec** compiled in for `vec_distance_cosine()` vector similarity search
- **swift-embeddings** — on-device Nomic Embed Text v1.5 (768-dim) embeddings via Apple MLTensor/GPU
- **MCP Swift SDK** — Model Context Protocol server implementation with stdio transport
- **FTS5** — SQLite full-text search indexes for concept and chunk search
- **BFS** — breadth-first search over hypergraph edge adjacency for multi-hop reasoning paths
