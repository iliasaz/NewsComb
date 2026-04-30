// swiftlint:disable file_length

import Foundation
import MCP

/// Registers all NewsComb MCP tools and dispatches tool calls.
/// Uses the app's `Database.current` directly — no separate database wrapper needed.
// swiftlint:disable:next type_body_length
struct MCPToolHandler: Sendable {

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
                name: "refresh_feeds",
                description: "Trigger a feed refresh — equivalent to pressing the Refresh button in the NewsComb UI. Fetches every RSS source, extracts content, and updates the in-app metrics. The UI reflects progress in real time.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true (default), block until refresh completes and return a summary. If false, fire-and-forget and poll get_app_status.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "create_manual_feed",
                description: "Create a 'manual' feed — a container for articles ingested directly via MCP (e.g. when no RSS source exists). The feed is stored as an rss_source row with a synthetic 'manual:' URL that the regular RSS refresh path skips. Use the returned source_id with ingest_article.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("Human-readable feed title shown in the UI.")
                        ])
                    ]),
                    "required": .array([.string("title")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "ingest_article",
                description: "Ingest a single article into an existing manual feed. Body is stored as full_content. Re-calling with the same (source_id, guid) — or same source_id and link, when guid is omitted — updates the existing row instead of creating a duplicate. Refuses to ingest into real RSS feeds.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "source_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the manual feed (returned by create_manual_feed).")
                        ]),
                        "title": .object([
                            "type": .string("string"),
                            "description": .string("Article title.")
                        ]),
                        "body": .object([
                            "type": .string("string"),
                            "description": .string("Full article text (Markdown or plain text). Minimum 100 chars after trimming.")
                        ]),
                        "link": .object([
                            "type": .string("string"),
                            "description": .string("Optional canonical URL. When omitted, a synthetic 'manual:item:<uuid>' is generated. Used as the dedup key when guid is not provided.")
                        ]),
                        "author": .object([
                            "type": .string("string"),
                            "description": .string("Optional author name.")
                        ]),
                        "pub_date": .object([
                            "type": .string("string"),
                            "description": .string("Optional publication date as ISO8601 (e.g. 2026-04-29T12:00:00Z).")
                        ]),
                        "guid": .object([
                            "type": .string("string"),
                            "description": .string("Optional explicit GUID. Defaults to link. Determines upsert behavior under (source_id, guid).")
                        ])
                    ]),
                    "required": .array([.string("source_id"), .string("title"), .string("body")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "refresh_article",
                description: "Re-fetch full_content for a single article from its link, independently of the parent feed. Uses the same Postlight extraction pipeline as the RSS refresh. Updates the link if the page now redirects elsewhere. Rejects articles whose link scheme is not http(s) (e.g. manually-composed articles with no real source URL).",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "feed_item_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the article to refresh (from get_recent_articles or feed_item.id).")
                        ])
                    ]),
                    "required": .array([.string("feed_item_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "reprocess_article",
                description: "Drop and re-extract knowledge graph state for a single article. Use after ingest_article when you want the graph to reflect the new body immediately rather than waiting for the next batch process_knowledge_graph run. Atomically deletes the article's chunks, edges, incidences, and provenance, then sweeps any nodes that became globally orphaned (no remaining incidences), then re-runs the per-article extraction pipeline. Returns counts of dropped and re-extracted rows.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "feed_item_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the article to reprocess (from get_recent_articles or feed_item.id).")
                        ])
                    ]),
                    "required": .array([.string("feed_item_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "process_knowledge_graph",
                description: "Trigger LLM extraction over unprocessed articles — equivalent to the 'Process Knowledge Graph' toolbar button. Persists new entities, relationships, embeddings, and auto-simplifies the graph. The UI shows live progress.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until processing finishes (can take many minutes). Default false: returns immediately and you should poll get_app_status.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "cancel_knowledge_graph_processing",
                description: "Cancel a running knowledge graph processing job — equivalent to the 'Stop' button shown while processing.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "rebuild_themes",
                description: "Trigger theme clustering — equivalent to the 'Recompute All' menu item in the Themes view. Runs the full PCA → UMAP → HDBSCAN pipeline and re-labels clusters. The UI shows the rebuild progress bar.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until clustering completes. Default false: returns immediately and you should poll get_app_status.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "regenerate_theme_summaries",
                description: "Re-run only the LLM labeling step on existing theme clusters — equivalent to 'Regenerate Summaries' in the Themes menu. Faster than a full rebuild.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until regeneration completes. Default false: returns immediately and you should poll get_app_status.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "split_cluster",
                description: "Re-cluster a single existing theme to surface its sub-structure. NON-DESTRUCTIVE: the parent cluster stays intact; discovered sub-clusters are inserted as TENTATIVE children with parent_cluster_id pointing back. Use save_split to promote them to permanent sub-themes, or discard_split to remove them. Events that don't fit any sub-cluster remain attached to the parent. Supports dry_run for preview-only without writing.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "cluster_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the cluster to split (from get_themes).")
                        ]),
                        "min_cluster_size": .object([
                            "type": .string("integer"),
                            "description": .string("Override HDBSCAN min cluster size for this split. Lower = more, smaller sub-clusters. Default: sqrt(N)/4 of the cluster's member count.")
                        ]),
                        "min_samples": .object([
                            "type": .string("integer"),
                            "description": .string("Override HDBSCAN min samples (core distance neighborhood). Default: app setting.")
                        ]),
                        "relabel": .object([
                            "type": .string("boolean"),
                            "description": .string("If true (default), re-run LLM labeling on the new sub-clusters. Ignored when dry_run is true.")
                        ]),
                        "dry_run": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, return the predicted sub-cluster sizes and noise count WITHOUT modifying the database. Use to preview before committing a destructive split. Default false.")
                        ]),
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until split completes. Default false: returns immediately, poll get_app_status.")
                        ])
                    ]),
                    "required": .array([.string("cluster_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "save_split",
                description: "Promote tentative children of a parent cluster to permanent sub-themes (clears their is_tentative flag). The parent cluster stays unchanged.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "parent_cluster_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the parent cluster whose tentative children should be saved.")
                        ]),
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until the operation completes. Default false.")
                        ])
                    ]),
                    "required": .array([.string("parent_cluster_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "discard_split",
                description: "Delete all tentative children of a parent cluster (cluster_members and cluster_exemplars cascade). The parent cluster stays unchanged.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "parent_cluster_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the parent cluster whose tentative children should be discarded.")
                        ]),
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until the operation completes. Default false.")
                        ])
                    ]),
                    "required": .array([.string("parent_cluster_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "identify_noise_pools",
                description: "List clusters flagged by the IQR-on-log(size) outlier rule as likely noise pools — absorption buckets that swallowed every event the density-based clusterer couldn't tightly group elsewhere. They are not real themes. Use drop_noise_pools to remove them.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "drop_noise_pools",
                description: "Drop clusters identified as noise pools. With no cluster_ids, drops all currently-flagged. Underlying graph data (nodes, edges, embeddings, articles) is preserved. Saved sub-themes of a dropped parent get unlinked and become top-level themes.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "cluster_ids": .object([
                            "type": .string("array"),
                            "description": .string("Optional: specific cluster IDs to drop. If omitted, drops every currently-flagged noise-pool cluster."),
                            "items": .object(["type": .string("integer")])
                        ]),
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until completion. Default false.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "extract_theme",
                description: "Extract events from a parent cluster matching a free-text phrase as a TENTATIVE sub-theme under the parent. Embeds the phrase with the same provider used for chunk_embedding, scores cosine similarity against each event's source-chunk embedding, and creates a tentative child from the top-K matches. Use save_split / discard_split to commit or undo.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "parent_cluster_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the parent cluster to extract from.")
                        ]),
                        "query": .object([
                            "type": .string("string"),
                            "description": .string("Free-text phrase, e.g. 'Google Spanner BigQuery'.")
                        ]),
                        "top_k": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum number of events to include. Default 200.")
                        ]),
                        "similarity_threshold": .object([
                            "type": .string("number"),
                            "description": .string("Minimum cosine similarity (0..1). Default 0.45.")
                        ]),
                        "relabel": .object([
                            "type": .string("boolean"),
                            "description": .string("Re-run LLM labeling on the new sub-theme. Default true. Ignored when dry_run is true.")
                        ]),
                        "dry_run": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, return predicted match count without writing. Default false.")
                        ]),
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until completion. Default false.")
                        ])
                    ]),
                    "required": .array([.string("parent_cluster_id"), .string("query")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "delete_cluster",
                description: "Delete a single cluster row. Underlying graph data (nodes, edges, embeddings, chunks, articles) is preserved. If the cluster is a parent: tentative children are removed, saved children are unlinked (their parent_cluster_id becomes NULL) and become top-level themes.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "cluster_id": .object([
                            "type": .string("integer"),
                            "description": .string("ID of the cluster to delete.")
                        ]),
                        "wait": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, block until the operation completes. Default false.")
                        ])
                    ]),
                    "required": .array([.string("cluster_id")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: true)
            ),
            Tool(
                name: "get_app_status",
                description: "Snapshot every long-running operation in the NewsComb app — feed refresh, knowledge graph processing, theme clustering — with progress, status messages, and last-error details. Use this to poll after triggering a background action.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: true, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_theme_provenance",
                description: "Returns the full member-event list for a theme with article and chunk-level provenance. Unlike get_theme_details (which shows top 10 exemplars), this gives every event with its membership score, source article, and optionally the chunk text it was extracted from.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "cluster_id": .object([
                            "type": .string("integer"),
                            "description": .string("Theme cluster ID (from get_themes).")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum member events to return (default 50).")
                        ]),
                        "min_membership": .object([
                            "type": .string("number"),
                            "description": .string("Minimum membership score, 0.0–1.0 (default 0.0).")
                        ]),
                        "include_chunk_text": .object([
                            "type": .string("boolean"),
                            "description": .string("If true, include the source chunk text (truncated to 500 chars).")
                        ]),
                        "source": .object([
                            "type": .string("string"),
                            "description": .string("Optional: only include events whose source article comes from an RSS source matching this name (substring match).")
                        ])
                    ]),
                    "required": .array([.string("cluster_id")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "compare_themes",
                description: "Compare two or more themes by centroid cosine similarity, top-entity Jaccard overlap, and shared source articles. Useful for spotting near-duplicate clusters or unexpectedly related stories.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "cluster_ids": .object([
                            "type": .string("array"),
                            "description": .string("Two or more cluster IDs to compare."),
                            "items": .object(["type": .string("integer")])
                        ])
                    ]),
                    "required": .array([.string("cluster_ids")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_entity_themes",
                description: "Lists every theme an entity participates in, ranked by how many of the entity's edges fall into each theme. Answers questions like 'which themes is OpenAI involved in?'.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "entity_label": .object([
                            "type": .string("string"),
                            "description": .string("Entity label (case-insensitive). Use search_concepts first if unsure of the exact label.")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum themes to return (default 20).")
                        ])
                    ]),
                    "required": .array([.string("entity_label")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "find_articles_across_themes",
                description: "Find 'hub' articles whose extracted relationships span multiple theme clusters. Ranked by number of distinct themes touched. Useful for editorial analysis and trend correlation.",
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "min_themes": .object([
                            "type": .string("integer"),
                            "description": .string("Minimum number of themes an article must span (default 2).")
                        ]),
                        "limit": .object([
                            "type": .string("integer"),
                            "description": .string("Maximum articles to return (default 20).")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_settings",
                description: """
                    Read workspace-scoped app_settings rows grouped by SettingsCategory \
                    (extraction, clustering, rag, analysis, llm, feeds, simulation). \
                    Secret values (API keys) are returned as '<redacted>' unless \
                    include_secrets is true. Output is a JSON object keyed by category, \
                    where each value is a {key: string-value} map. Missing rows surface \
                    as empty strings so the schema is stable.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "category": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("extraction"),
                                .string("clustering"),
                                .string("rag"),
                                .string("analysis"),
                                .string("llm"),
                                .string("feeds"),
                                .string("simulation")
                            ]),
                            "description": .string("Optional. If omitted, returns all categories.")
                        ]),
                        "include_secrets": .object([
                            "type": .string("boolean"),
                            "default": .bool(false),
                            "description": .string("If true, return raw API key values; otherwise '<redacted>'.")
                        ])
                    ])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "update_settings",
                description: """
                    Update workspace-scoped app_settings rows for a single SettingsCategory. \
                    All keys must belong to the named category, and every value is validated \
                    against the same bounds the SettingsView Steppers enforce. Validation is \
                    atomic: if any value is invalid, the entire batch is rejected and no rows \
                    are written. After a successful write, side-effects fire automatically \
                    (e.g. changing an LLM embedding setting rebuilds the sqlite-vec tables).
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "category": .object([
                            "type": .string("string"),
                            "enum": .array([
                                .string("extraction"),
                                .string("clustering"),
                                .string("rag"),
                                .string("analysis"),
                                .string("llm"),
                                .string("feeds"),
                                .string("simulation")
                            ]),
                            "description": .string("The settings category to update.")
                        ]),
                        "settings": .object([
                            "type": .string("object"),
                            "description": .string("Map of setting key → string value. All keys must belong to the named category. All values are validated before any write."),
                            "additionalProperties": .object(["type": .string("string")])
                        ])
                    ]),
                    "required": .array([.string("category"), .string("settings")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "list_parameter_presets",
                description: """
                    List every parameter preset in the workspace. Built-in presets \
                    (News Intelligence, Codebase Intelligence) sort first; user-defined \
                    presets follow alphabetically. Returns a JSON array of objects with \
                    name, description, is_builtin, and updated_at.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([:])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "get_parameter_preset",
                description: """
                    Fetch a single parameter preset by name, including the parsed \
                    settings dictionary. Secret values (API keys) are returned as \
                    '<redacted>' unless include_secrets is true.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Preset name (case-sensitive).")
                        ]),
                        "include_secrets": .object([
                            "type": .string("boolean"),
                            "default": .bool(false),
                            "description": .string("If true, return raw API key values; otherwise '<redacted>'.")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ]),
                annotations: .init(readOnlyHint: true, openWorldHint: false)
            ),
            Tool(
                name: "apply_parameter_preset",
                description: """
                    Apply a parameter preset to the workspace's app_settings. Every \
                    setting in the preset is validated atomically before any write — \
                    if any value is invalid the entire batch is rejected. After a \
                    successful write, side-effects fire automatically (e.g. embedding \
                    dimension changes rebuild the vec0 tables).
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Preset name to apply.")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "create_parameter_preset",
                description: """
                    Create a new user-defined parameter preset. All settings are \
                    validated against the same bounds as update_settings. Keys that \
                    don't belong to a known SettingsCategory are rejected. Fails if \
                    a preset with the given name already exists — use \
                    update_parameter_preset to modify an existing preset.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Unique preset name.")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("Human-readable description shown in the picker.")
                        ]),
                        "settings": .object([
                            "type": .string("object"),
                            "description": .string("Map of setting key → string value. All values are validated."),
                            "additionalProperties": .object(["type": .string("string")])
                        ])
                    ]),
                    "required": .array([.string("name"), .string("description"), .string("settings")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "update_parameter_preset",
                description: """
                    Update an existing parameter preset. Description and settings are \
                    optional — omitted fields are preserved. Settings are merged into \
                    the preset's existing settings_json (overwrite by key). Built-in \
                    presets can be edited; their is_builtin flag is never changed. \
                    Validation is atomic.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Preset name to update.")
                        ]),
                        "description": .object([
                            "type": .string("string"),
                            "description": .string("Optional. New description; if omitted the existing one is preserved.")
                        ]),
                        "settings": .object([
                            "type": .string("object"),
                            "description": .string("Optional. Map of setting key → string value to merge into the preset."),
                            "additionalProperties": .object(["type": .string("string")])
                        ])
                    ]),
                    "required": .array([.string("name")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
            ),
            Tool(
                name: "delete_parameter_preset",
                description: """
                    Delete a user-defined parameter preset. Built-in presets are \
                    protected — call reset_parameter_preset on a built-in to restore \
                    its seeded defaults instead.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Preset name to delete.")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: true, idempotentHint: false, openWorldHint: false)
            ),
            Tool(
                name: "reset_parameter_preset",
                description: """
                    Reset a built-in parameter preset to its seeded defaults. For \
                    user-defined presets this is a friendly no-op (no error). Use \
                    this to undo edits to News Intelligence or Codebase Intelligence.
                    """,
                inputSchema: .object([
                    "type": .string("object"),
                    "properties": .object([
                        "name": .object([
                            "type": .string("string"),
                            "description": .string("Preset name to reset.")
                        ])
                    ]),
                    "required": .array([.string("name")])
                ]),
                annotations: .init(readOnlyHint: false, destructiveHint: false, idempotentHint: true, openWorldHint: false)
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

        await server.withMethodHandler(ListTools.self) { _ in
            .init(tools: capturedTools)
        }

        await server.withMethodHandler(CallTool.self) { params in
            do {
                let result = try await MCPToolDispatcher.dispatch(
                    toolName: params.name,
                    arguments: params.arguments ?? [:]
                )
                return .init(
                    content: [.text(text: result, annotations: nil, _meta: nil)],
                    isError: false
                )
            } catch let error as MCPToolError {
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
