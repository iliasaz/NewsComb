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

- macOS 26+ with Swift 6.2+
- A populated NewsComb database (run the NewsComb app first to ingest feeds and extract knowledge)

## Build

```bash
cd NewsCombMCP
swift build -c release
```

The built binary will be at `.build/release/newscomb-mcp`.

## Configuration

The server locates the NewsComb database automatically at:
```
~/Library/Application Support/NewsComb/newscomb.sqlite
```

Override with the `NEWSCOMB_DB_PATH` environment variable:
```bash
NEWSCOMB_DB_PATH=/path/to/newscomb.sqlite .build/release/newscomb-mcp
```

## Usage with Claude Code

Add to your Claude Code MCP settings (`~/.claude/claude_desktop_config.json` or project `.mcp.json`):

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsCombMCP/.build/release/newscomb-mcp"
    }
  }
}
```

Or with a custom database path:

```json
{
  "mcpServers": {
    "newscomb": {
      "command": "/path/to/NewsCombMCP/.build/release/newscomb-mcp",
      "env": {
        "NEWSCOMB_DB_PATH": "/path/to/newscomb.sqlite"
      }
    }
  }
}
```

## Example Workflows

### Research a topic (recommended)
1. `query_knowledge_graph` with your question — runs the full RAG pipeline automatically
2. Use the returned context (concepts, reasoning paths, relationships, source text) to synthesize your answer

### Research a topic (manual exploration)
1. `search_concepts` with query "quantum computing"
2. `get_node_neighbors` for an interesting entity
3. `find_paths` between two related concepts
4. `search_chunks` for supporting evidence

### Explore themes
1. `get_themes` to browse all discovered themes
2. `get_theme_details` for themes of interest
3. `search_concepts` for entities mentioned in themes

### Monitor feeds
1. `get_statistics` for an overview
2. `get_recent_articles` to see latest ingested content
3. `search_chunks` for specific topics in recent articles

## Architecture

The MCP server opens the NewsComb SQLite database in **read-only** mode, so it can run concurrently with the main NewsComb app without conflicts. It uses:

- **GRDBCustom** for database access (via `DatabasePool` in read-only mode) with **sqlite-vec** compiled in for vector similarity search
- **swift-embeddings** for on-device Nomic Embed Text v1.5 (768-dim) embeddings via Apple MLTensor/GPU
- **MCP Swift SDK** for the Model Context Protocol implementation
- **stdio transport** for communication with MCP clients
- **sqlite-vec** `vec_distance_cosine()` for semantic similarity search over node and chunk embeddings
- **FTS5** full-text search indexes for concept and chunk search
- **BFS path finding** over the hypergraph for multi-hop reasoning
