# NewsComb MCP Server

An [MCP (Model Context Protocol)](https://modelcontextprotocol.io) server that exposes NewsComb's knowledge intelligence features to AI assistants like Claude Code, Claude Work, and Codex.

## Features

The MCP server provides read-only access to NewsComb's knowledge graph:

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
- A populated NewsComb database (run the NewsComb app first to ingest feeds and extract knowledge)
- The Nomic Embed Text v1.5 model will be downloaded automatically from Hugging Face Hub on first use of `query_knowledge_graph`

## Build

```bash
cd NewsCombMCP
swift build -c release
```

The built binary will be at `.build/release/newscomb-mcp`.

## Setup with Claude Code

### 1. Build the server

```bash
cd /path/to/NewsComb/NewsCombMCP
swift build -c release
```

### 2. Add to Claude Code configuration

Create or edit `.mcp.json` in your project root (or `~/.claude/settings.json` for global access):

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsComb/NewsCombMCP/.build/release/newscomb-mcp"
    }
  }
}
```

Replace `/path/to/NewsComb` with the actual path to your NewsComb repository.

If your database is in a non-default location, add an `env` block:

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

### 3. Verify in Claude Code

After restarting Claude Code, the tools should appear automatically. You can verify by asking:

> "What tools do you have from newscomb?"

or:

> "Use the newscomb query_knowledge_graph tool to tell me about recent AI developments"

## Setup with Claude Desktop

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

## Database Location

The server automatically looks for the database at:
```
~/Library/Application Support/NewsComb/newscomb.sqlite
```

This is the default location used by the NewsComb app. Override it with the `NEWSCOMB_DB_PATH` environment variable if needed.

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

This is a **standalone CLI executable** that communicates via stdio transport. It opens the NewsComb SQLite database in **read-only** mode, so it runs safely alongside the main NewsComb app.

### Why a separate executable?

MCP servers communicate over stdio (stdin/stdout) and run as headless CLI processes. The NewsComb app is a SwiftUI application with a GUI lifecycle, which makes it unsuitable as a stdio server host. The separate executable allows the MCP server to start and stop independently of the app.

The trade-off is some code duplication — the MCP server reimplements the embedding service, BFS path finding, and SQL queries that also exist in the main app. A future improvement would be to extract shared logic into a common Swift library target that both the app and the MCP server depend on.

### Dependencies

- **GRDBCustom** — local package providing GRDB with **sqlite-vec** compiled in for `vec_distance_cosine()` vector similarity search
- **swift-embeddings** — on-device Nomic Embed Text v1.5 (768-dim) embeddings via Apple MLTensor/GPU
- **MCP Swift SDK** — Model Context Protocol server implementation with stdio transport
- **FTS5** — SQLite full-text search indexes for concept and chunk search
- **BFS** — breadth-first search over hypergraph edge adjacency for multi-hop reasoning paths
