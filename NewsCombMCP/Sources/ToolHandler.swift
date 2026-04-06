import Foundation
import MCP

/// Registers all NewsComb MCP tools and dispatches tool calls.
struct ToolHandler: Sendable {
    let database: ReadOnlyDatabase

    /// All available tools with their JSON Schema definitions.
    private var tools: [Tool] {
        [
            Tool(
                name: "search_concepts",
                description: "Search for entities and concepts in the knowledge graph using full-text search. Returns matching nodes with their type and document frequency.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query for concept names (supports FTS5 syntax: AND, OR, NOT, prefix*)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of results (default: 20)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "search_chunks",
                description: "Search article text chunks for specific content using full-text search. Returns matching chunks with their source article title and link.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Search query for article content (supports FTS5 syntax)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of results (default: 10)")
                        ])
                    ]),
                    "required": .array([.string("query")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_node_neighbors",
                description: "Get all relationships (hyperedges) connected to a concept/entity. Returns edges with their source and target nodes, relationship labels, and provenance text from articles.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "node_label": .object([
                            "type": .string("string"),
                            "description": .string("The label of the node to explore (case-insensitive)")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of edges to return (default: 30)")
                        ])
                    ]),
                    "required": .array([.string("node_label")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "find_paths",
                description: "Find multi-hop reasoning paths between two concepts in the knowledge hypergraph. Traverses the graph via shared nodes between hyperedges (s-connectivity) using BFS. Returns causal chains like: 'NVIDIA → competes with → AMD → partners with → Microsoft'.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Source concept label (case-insensitive)")
                        ]),
                        "target": .object([
                            "type": .string("string"),
                            "description": .string("Target concept label (case-insensitive)")
                        ]),
                        "max_depth": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum BFS depth / path length (default: 4)")
                        ]),
                        "max_paths": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of paths to return (default: 3)")
                        ])
                    ]),
                    "required": .array([.string("source"), .string("target")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_themes",
                description: "List story theme clusters discovered by HDBSCAN clustering. Each theme represents a group of semantically related news events with an auto-generated label, size, top entities, and optional LLM summary. Themes are sorted by size (largest first).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of themes to return (default: 20)")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Optional full-text search to filter themes by label or summary")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_theme_details",
                description: "Get detailed information about a specific story theme cluster, including its top entities, relationship families, exemplar events (with full edge labels and participant nodes), and the LLM-generated summary.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "cluster_id": .object([
                            "type": .string("integer"),
                            "description": .string("The cluster ID to get details for")
                        ])
                    ]),
                    "required": .array([.string("cluster_id")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_statistics",
                description: "Get knowledge graph statistics: total nodes, edges, processed articles, embeddings count, and article chunk count.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_recent_articles",
                description: "List recently ingested articles from RSS feeds with their title, source, publication date, and link.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of articles to return (default: 20)")
                        ]),
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Optional: filter by RSS source title (case-insensitive substring match)")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "query_knowledge_graph",
                description: """
                    Full RAG query over the knowledge hypergraph. Given a natural language question, this tool: \
                    (1) extracts keywords, (2) embeds them with on-device Nomic embeddings, \
                    (3) finds similar concepts via vector search, (4) discovers multi-hop reasoning paths between them via BFS, \
                    (5) gathers supporting relationships and article chunks. \
                    Returns grounded context (concepts, reasoning paths, relationships, source text, articles) \
                    for you to synthesize into an answer. Use this as your primary research tool for complex questions.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "question": .object([
                            "type": .string("string"),
                            "description": .string("The natural language question to research in the knowledge graph")
                        ]),
                        "max_nodes": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum similar nodes to retrieve per keyword (default: 5)")
                        ]),
                        "max_chunks": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum source text chunks to retrieve (default: 5)")
                        ]),
                        "max_path_depth": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum BFS depth for reasoning paths (default: 4)")
                        ])
                    ]),
                    "required": .array([.string("question")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
        ]
    }

    /// Register ListTools and CallTool handlers on the server.
    func register(on server: Server) async {
        let capturedTools = tools
        let db = database

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: capturedTools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let result = try await ToolDispatcher.dispatch(
                    toolName: params.name,
                    arguments: params.arguments ?? [:],
                    database: db
                )
                return .init(
                    content: [.text(text: result, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch let error as ToolError {
                return .init(
                    content: [.text(text: error.message, annotations: nil, _meta: nil)],
                    isError: true
                )
            } catch {
                return .init(
                    content: [.text(text: "Internal error: \(error.localizedDescription)", annotations: nil, _meta: nil)],
                    isError: true
                )
            }
        }
    }
}
