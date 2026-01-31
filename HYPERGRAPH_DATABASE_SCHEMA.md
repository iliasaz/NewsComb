# Hypergraph Database Schema

This document describes every table in the SQLite database related to the knowledge graph (hypergraph) subsystem. All tables are defined in `NewsCombApp/Services/DatabaseService.swift` inside the `migrate()` method.

Articles and feed sources are managed by the `rss_source` and `feed_item` tables, which are intentionally excluded from this document. Settings live in `app_settings`.


## Table Overview

| Table | Kind | Purpose |
|-------|------|---------|
| `hypergraph_node` | regular | Knowledge graph entities (concepts, people, places, etc.) |
| `hypergraph_edge` | regular | Relationships between nodes |
| `hypergraph_incidence` | regular | Maps nodes to edges with roles (source, target, context) |
| `article_hypergraph` | regular | Tracks which articles have been processed |
| `article_edge_provenance` | regular | Links edges back to source articles and chunks |
| `article_chunk` | regular | Text chunks split from articles for fine-grained provenance |
| `node_embedding` | vec0 virtual | 768-dim float vectors for node semantic search |
| `node_embedding_metadata` | regular | Timestamps and model info for node embeddings |
| `chunk_embedding` | vec0 virtual | 768-dim float vectors for chunk semantic search |
| `chunk_embedding_metadata` | regular | Timestamps and model info for chunk embeddings |
| `node_merge_history` | regular | Audit trail of merged duplicate nodes |
| `query_history` | regular | Persisted user questions, answers, and reasoning paths |
| `event_vectors` | vec0 virtual | 2316-dim vectors for edge clustering |
| `clusters` | regular | HDBSCAN cluster definitions with centroids and metadata |
| `event_cluster` | regular | Maps every edge to its cluster assignment |
| `cluster_members` | regular | Non-noise cluster members (denormalized for quick lookup) |
| `cluster_exemplars` | regular | Top exemplar edges per cluster ranked by centroid proximity |
| `fts_node` | FTS5 virtual | Full-text search index on node labels |
| `fts_chunk` | FTS5 virtual | Full-text search index on chunk content |
| `user_role` | regular | Persona-based prompts for query customization |


## Core Hypergraph Tables

### `hypergraph_node`

Stores extracted entities (concepts, people, organizations, locations, events, etc.).

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment surrogate key |
| `node_id` | TEXT UNIQUE | Stable string identifier (e.g., `"entity_climate_change"`) |
| `label` | TEXT | Human-readable display name |
| `node_type` | TEXT | Category (e.g., `"person"`, `"organization"`, `"concept"`) |
| `first_seen_at` | REAL | Unix epoch timestamp |
| `metadata_json` | TEXT | Optional JSON blob for extra attributes |
| `df` | INTEGER | Document frequency (number of edges this node participates in) |
| `idf` | REAL | Inverse document frequency for TF-IDF weighting |

**Indexes:** `idx_hypergraph_node_id` on `node_id`.

### `hypergraph_edge`

Represents a relationship extracted from article text.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment surrogate key |
| `edge_id` | TEXT UNIQUE | Stable string identifier |
| `label` | TEXT | Relationship description (e.g., `"announced policy on"`) |
| `created_at` | REAL | Unix epoch timestamp |
| `metadata_json` | TEXT | Optional JSON blob |
| `source_chunk_id` | INTEGER FK | References `article_chunk(id)` — the chunk this edge was extracted from |

**Indexes:** `idx_hypergraph_edge_id` on `edge_id`, `idx_hypergraph_edge_label` on `label`, `idx_hypergraph_edge_chunk` on `source_chunk_id`.

### `hypergraph_incidence`

Junction table connecting nodes to edges. Each incidence record assigns a node a **role** within an edge (e.g., source, target, context).

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment |
| `edge_id` | INTEGER FK | References `hypergraph_edge(id)` ON DELETE CASCADE |
| `node_id` | INTEGER FK | References `hypergraph_node(id)` ON DELETE CASCADE |
| `role` | TEXT | `"source"`, `"target"`, or `"context"` |
| `position` | INTEGER | Ordering within the role (default 0) |

**Unique constraint:** `(edge_id, node_id, role)`.
**Indexes:** `idx_hypergraph_incidence_edge`, `idx_hypergraph_incidence_node`.


## Article Processing Tables

### `article_hypergraph`

Tracks which articles have been processed for knowledge extraction. Deleting rows from this table causes articles to appear as "unprocessed" again.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment |
| `feed_item_id` | INTEGER FK | References `feed_item(id)` ON DELETE CASCADE |
| `processed_at` | REAL | Unix epoch timestamp |
| `processing_status` | TEXT | `"pending"`, `"completed"`, or `"failed"` |
| `error_message` | TEXT | Error detail if status is `"failed"` |
| `chunk_count` | INTEGER | Number of chunks the article was split into |

**Unique constraint:** `(feed_item_id)`.
**Indexes:** `idx_article_hypergraph_status`.

### `article_chunk`

Text chunks split from articles for fine-grained provenance and embedding.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment |
| `feed_item_id` | INTEGER FK | References `feed_item(id)` ON DELETE CASCADE |
| `chunk_index` | INTEGER | Zero-based position within the article |
| `content` | TEXT | The chunk text |
| `created_at` | REAL | Unix epoch timestamp |

**Unique constraint:** `(feed_item_id, chunk_index)`.
**Indexes:** `idx_article_chunk_feed`.

### `article_edge_provenance`

Links extracted edges back to the specific article and chunk they came from.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment |
| `edge_id` | INTEGER FK | References `hypergraph_edge(id)` ON DELETE CASCADE |
| `feed_item_id` | INTEGER FK | References `feed_item(id)` ON DELETE CASCADE |
| `chunk_index` | INTEGER | Which chunk within the article |
| `chunk_text` | TEXT | Snapshot of the chunk text at extraction time |
| `confidence` | REAL | LLM confidence score |

**Unique constraint:** `(edge_id, feed_item_id, chunk_index)`.
**Indexes:** `idx_article_edge_provenance_edge`, `idx_article_edge_provenance_feed`.


## Embedding Tables

Vector embedding dimensions are **configurable** via the `embedding_dimension` app setting (default: **3072**, matching `openai/text-embedding-3-large` via OpenRouter). The vec0 virtual tables are created dynamically with the configured dimension. When the dimension changes, a knowledge graph reset (or processing from an empty graph) triggers automatic recreation of the vec0 tables. The `active_embedding_dimension` setting tracks what the tables were last created with.

### `node_embedding` (vec0 virtual table)

| Column | Type | Notes |
|--------|------|-------|
| `node_id` | INTEGER PK | Matches `hypergraph_node(id)` |
| `embedding` | float[*dim*] | Semantic embedding vector (`dim` = `embedding_dimension` setting) |

### `node_embedding_metadata`

| Column | Type | Notes |
|--------|------|-------|
| `node_id` | INTEGER PK FK | References `hypergraph_node(id)` ON DELETE CASCADE |
| `computed_at` | REAL | Unix epoch timestamp |
| `model_name` | TEXT | Model that produced the embedding |
| `embedding_version` | INTEGER | Version counter (default 1) |

### `chunk_embedding` (vec0 virtual table)

| Column | Type | Notes |
|--------|------|-------|
| `chunk_id` | INTEGER PK | Matches `article_chunk(id)` |
| `embedding` | float[*dim*] | Semantic embedding vector (`dim` = `embedding_dimension` setting) |

### `chunk_embedding_metadata`

| Column | Type | Notes |
|--------|------|-------|
| `chunk_id` | INTEGER PK FK | References `article_chunk(id)` ON DELETE CASCADE |
| `computed_at` | REAL | Unix epoch timestamp |
| `model_name` | TEXT | Model that produced the embedding |
| `embedding_version` | INTEGER | Version counter (default 1) |


## Node Merge History

### `node_merge_history`

Audit trail of node deduplication. When similar nodes are merged, the "removed" node's edges are reassigned to the "kept" node.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment |
| `merged_at` | REAL | Unix epoch timestamp |
| `kept_node_id` | INTEGER FK | References `hypergraph_node(id)` — the surviving node |
| `removed_node_id` | INTEGER | ID of the node that was deleted |
| `removed_node_label` | TEXT | Label snapshot of the removed node |
| `similarity_score` | REAL | Cosine similarity between the two node embeddings |

**Indexes:** `idx_node_merge_history_kept`.


## Query History

### `query_history`

Persists user questions and their AI-generated answers, including graph traversal paths and deep analysis.

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment |
| `query` | TEXT | The user's question |
| `answer` | TEXT | The generated answer |
| `related_nodes_json` | TEXT | JSON array of related node IDs |
| `graph_paths_json` | TEXT | JSON representation of graph traversal paths |
| `source_articles_json` | TEXT | JSON array of source article references |
| `reasoning_paths_json` | TEXT | JSON representation of reasoning chains |
| `deep_analysis_json` | TEXT | Legacy column for "Dive Deeper" analysis |
| `synthesized_analysis` | TEXT | Synthesized multi-hop analysis text |
| `hypotheses` | TEXT | Generated hypotheses from analysis |
| `analyzed_at` | REAL | Timestamp of deep analysis |
| `created_at` | REAL | Unix epoch timestamp |

**Indexes:** `idx_query_history_created` on `created_at DESC`.


## Theme Clustering Tables

These tables support HDBSCAN-based story theme detection. Event vectors are computed by `EventVectorService` and stored in `event_vectors`, then clustered into themes.

### Event Vector Layout

Event vectors are computed as `3 * embeddingDim + RelationFamily.count` dimensional, constructed as:

```
[normalize(sourceVec) | normalize(targetVec) | normalize(diffVec) | relationFamilyOneHot]
     dim dims               dim dims               dim dims              12 dims
```

- `sourceVec` / `targetVec`: IDF-weighted mean of source/target node embeddings
- `diffVec`: `targetVec - sourceVec`
- `relationFamilyOneHot`: One-hot encoding of the `RelationFamily` enum

Values in `EventVectorService` (read from settings at init):
- `embeddingDim` = `embedding_dimension` setting (default 3072)
- `eventVecDim = 3 * embeddingDim + RelationFamily.count`
- `idfMax = 6.0` (clamp for hub nodes)

### `event_vectors` (vec0 virtual table)

| Column | Type | Notes |
|--------|------|-------|
| `event_id` | INTEGER PK | Matches `hypergraph_edge(id)` |
| `vec` | float[*eventVecDim*] | Concatenated event vector (`3 * embeddingDim + 12`) |

### `clusters`

| Column | Type | Notes |
|--------|------|-------|
| `cluster_id` | INTEGER PK | Cluster identifier |
| `build_id` | TEXT | Identifies which clustering run produced this |
| `label` | TEXT | Human-readable cluster label |
| `size` | INTEGER | Number of members |
| `centroid_vec` | BLOB | Centroid vector (binary) |
| `top_entities_json` | TEXT | JSON array of top entity names |
| `top_rel_families_json` | TEXT | JSON array of top relation families |
| `created_at` | REAL | Unix epoch timestamp |

**Indexes:** `idx_clusters_build`.

### `event_cluster`

Maps every edge to its cluster assignment for a given build.

| Column | Type | Notes |
|--------|------|-------|
| `event_id` | INTEGER PK | Edge ID |
| `build_id` | TEXT | Clustering run identifier |
| `cluster_id` | INTEGER | Assigned cluster |
| `membership` | REAL | Soft membership score (default 1.0) |

**Indexes:** `idx_event_cluster_build`, `idx_event_cluster_cluster`.

### `cluster_members`

Denormalized table for fast cluster membership lookups (excludes noise points).

| Column | Type | Notes |
|--------|------|-------|
| `cluster_id` | INTEGER FK | References `clusters(cluster_id)` ON DELETE CASCADE |
| `event_id` | INTEGER | Edge ID |
| `membership` | REAL | Soft membership score |

**Primary key:** `(cluster_id, event_id)`.

### `cluster_exemplars`

Top-N exemplar edges for each cluster, ranked by proximity to centroid.

| Column | Type | Notes |
|--------|------|-------|
| `cluster_id` | INTEGER FK | References `clusters(cluster_id)` ON DELETE CASCADE |
| `event_id` | INTEGER | Edge ID |
| `rank` | INTEGER | 0 = closest to centroid |

**Primary key:** `(cluster_id, rank)`.


## FTS5 Full-Text Search Indexes

Both FTS5 tables use **external content** mode (no data duplication) with Porter stemming and Unicode61 tokenization.

### `fts_node`

Indexes `hypergraph_node.label`. Kept in sync via triggers (`fts_node_ai`, `fts_node_ad`, `fts_node_au`).

### `fts_chunk`

Indexes `article_chunk.content`. Kept in sync via triggers (`fts_chunk_ai`, `fts_chunk_ad`, `fts_chunk_au`).


## User Roles

### `user_role`

| Column | Type | Notes |
|--------|------|-------|
| `id` | INTEGER PK | Auto-increment |
| `name` | TEXT UNIQUE | Role name |
| `prompt` | TEXT | System prompt for this persona |
| `is_active` | INTEGER | 0 or 1; at most one active at a time |
| `created_at` | REAL | Unix epoch timestamp |
| `updated_at` | REAL | Unix epoch timestamp |

**Unique index:** `idx_user_role_active` WHERE `is_active = 1` — enforces single active role.


## Foreign Key Dependency Order

When deleting graph data, tables must be cleared in dependency order (children before parents) to respect foreign key constraints:

```
cluster_exemplars
cluster_members
event_cluster
clusters
event_vectors
article_edge_provenance
node_merge_history
chunk_embedding_metadata
chunk_embedding
node_embedding_metadata
node_embedding
fts_node  (rebuild after delete)
fts_chunk (rebuild after delete)
hypergraph_incidence
hypergraph_edge
hypergraph_node
article_chunk
article_hypergraph
query_history
```

This order is used by `MainViewModel.resetKnowledgeGraph()` to safely clear all graph data while preserving articles and feed sources.
