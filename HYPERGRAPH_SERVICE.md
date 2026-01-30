# Hypergraph Processing Service

This document describes the knowledge extraction, storage, and retrieval architecture that powers NewsComb's question-answering capabilities. The system converts RSS articles into a queryable knowledge graph using LLM-based entity/relation extraction, semantic embeddings, and hypergraph-based reasoning.

---

## Architecture Overview

```
RSS Articles
    |
    v
TextChunker ── splits into ~800-char chunks
    |
    v
DocumentProcessor (HyperGraphReasoning package)
    |
    ├── HypergraphExtractor ── LLM extracts Subject-Verb-Object triples
    |       |
    |       v
    |   Hypergraph<String, String> + ChunkMetadata[]
    |
    └── EmbeddingService ── Ollama generates 768-dim vectors
            |
            v
        NodeEmbeddings
    |
    v
HypergraphService (app layer) ── persists to SQLite via GRDB
    |
    v
GraphRAGService ── queries graph + generates answers via AsyncStream
    |
    v
DeepAnalysisService ── multi-agent synthesis and hypothesis generation
```

---

## Ingestion Pipeline

### 1. Text Chunking

**`TextChunker`** splits article content into chunks suitable for LLM processing.

- **Target size:** 800 characters (configurable).
- **Cascading fallback strategy:** paragraphs (double newline) > lines (single newline) > sentences > word boundaries.
- Preserves natural boundaries so each chunk retains coherent context.
- Force-splits extremely long tokens (e.g. URLs) that exceed the target.

### 2. Knowledge Extraction

**`DocumentProcessor`** (HyperGraphReasoning package) orchestrates the full extraction pipeline:

1. Optionally distills raw text using a configurable system prompt.
2. Splits text into chunks via `RecursiveTextSplitter` (configurable size and overlap).
3. Passes each chunk to **`HypergraphExtractor`**, which calls the configured LLM with a specialized prompt to extract Subject-Verb-Object triples.
4. Each triple becomes a hyperedge connecting two or more nodes.
5. Returns a `ProcessingResult` containing the hypergraph, per-edge metadata, embeddings, and a chunk index for provenance.

**Edge ID format:** `"relation_chunkXXX_N"` where the prefix is the relation name (underscores for spaces), `chunkXXX` identifies the source chunk, and `N` is the edge index within that chunk. Example: `"partnered_with_chunk0_2"`.

### 3. Embedding Generation

**`EmbeddingService`** (HyperGraphReasoning package) generates 768-dimensional vectors for each node label using an Ollama embedding model.

- Batch processing (default 100 texts per batch).
- Incremental: only generates embeddings for nodes that don't already have one.
- Pruning support to remove embeddings for deleted nodes.
- Similarity search via cosine similarity.

### 4. Persistence

**`HypergraphService`** (app layer) persists extracted data to SQLite:

- **Nodes** go into `hypergraph_node` with FTS5 full-text indexing.
- **Edges** go into `hypergraph_edge` with a reference to the source chunk.
- **Incidences** (edge-node memberships) go into `hypergraph_incidence` with roles: `source`, `target`, or `member`.
- **Embeddings** go into `node_embedding` (sqlite-vec virtual table, `float[768]`).
- **Chunks** go into `article_chunk` with FTS5 indexing.
- **Provenance** links in `article_edge_provenance` map each edge back to the chunk text it was extracted from.
- Processing status tracked per article in `article_hypergraph` (pending/processing/completed/failed).

---

## Database Schema

### Core Tables

| Table | Purpose | Key Columns |
|-------|---------|-------------|
| `hypergraph_node` | Concept/entity nodes | `id`, `node_id` (unique), `label`, `node_type`, `metadata_json` |
| `hypergraph_edge` | Relationships (hyperedges) | `id`, `edge_id` (unique), `label`, `source_chunk_id` (FK) |
| `hypergraph_incidence` | Edge-node memberships | `edge_id` (FK), `node_id` (FK), `role`, `position` |
| `article_chunk` | Article text chunks | `feed_item_id` (FK), `chunk_index`, `content` |
| `article_edge_provenance` | Edge-to-chunk provenance | `edge_id` (FK), `feed_item_id` (FK), `chunk_index`, `confidence` |
| `article_hypergraph` | Per-article processing status | `feed_item_id` (FK, unique), `processing_status`, `chunk_count` |
| `node_merge_history` | Audit trail of node merges | `kept_node_id` (FK), `removed_node_label`, `similarity_score` |
| `query_history` | Persisted query results and analysis | `query`, `answer`, `reasoning_paths_json`, `synthesized_analysis` |

### Virtual Tables (sqlite-vec)

| Table | Purpose |
|-------|---------|
| `node_embedding` | 768-dim node vectors for similarity search |
| `node_embedding_metadata` | Tracks when/how each embedding was computed |
| `chunk_embedding` | 768-dim chunk vectors for similarity search |
| `chunk_embedding_metadata` | Tracks when/how each chunk embedding was computed |

### FTS5 Tables

| Table | Indexes |
|-------|---------|
| `fts_node` | Full-text search over `hypergraph_node.label` |
| `fts_chunk` | Full-text search over `article_chunk.content` |

FTS tables are kept in sync via SQLite triggers on insert, update, and delete.

---

## Query Pipeline (GraphRAGService)

`GraphRAGService` implements a six-phase RAG pipeline. Results are delivered progressively via `AsyncStream<QueryPhaseUpdate>`, enabling immediate UI updates as each phase completes.

### Phase 1: Keyword Extraction

The LLM extracts 2-5 keywords from the user's question. The prompt asks for a JSON array; if the LLM returns non-JSON, a heuristic fallback splits the response on commas.

### Phase 2: Knowledge Graph Search

Each keyword is embedded using the configured embedding model. The resulting vectors are compared against `node_embedding` using cosine distance, with a threshold of 0.5. Matching nodes are deduplicated across keywords and sorted by distance.

**Stream update:** `.relatedNodes([RelatedNode])`

### Phase 3: Reasoning Path Discovery

**`HypergraphPathService`** performs multi-source BFS across the hypergraph to find shortest paths between matched node pairs:

- Builds an in-memory hypergraph index with precomputed edge adjacency.
- Uses s-connectivity (edges share >= threshold nodes).
- A single multi-source BFS traversal finds paths for all pairs efficiently (~100x faster than pairwise BFS).
- Returns `PathReport` values containing edge sequences and hop details.

**Stream updates:** `.reasoningPaths([ReasoningPath])`, `.graphPaths([GraphPath])`

### Phase 4: Context Gathering

Collects text context for the LLM from two sources:
- **Edge provenance:** chunk text linked to edges along discovered paths.
- **Direct chunks:** chunks from articles associated with matched nodes.

### Phase 5: Answer Generation

The analysis LLM generates an answer using the gathered context. Token streaming is supported: each token is yielded as `.answerToken(String)` for real-time display. For non-streaming providers, the full answer is yielded as a single token.

**Stream update:** `.answerToken(String)` (per token)

### Phase 6: Response Assembly

The final `GraphRAGResponse` is assembled with reasoning paths, graph paths, source articles, and the generated answer. The response is persisted to `query_history`.

**Stream update:** `.completed(GraphRAGResponse)`

### Cancellation

The `AsyncStream`'s `onTermination` handler cancels the inner task. Each phase checks `Task.checkCancellation()`, so back-navigation in the UI cleanly terminates the pipeline with no partial history saved.

---

## Deep Analysis Service

`DeepAnalysisService` implements a multi-agent workflow inspired by the Python AutoGen framework. It runs two sequential LLM agents on top of a completed GraphRAG response:

### Agent 1: Engineer

Synthesizes the initial answer with the full knowledge graph context, producing an academic-style analysis with citations like [1], [2].

### Agent 2: Hypothesizer

Takes the synthesized analysis and graph context, then generates hypotheses, experiment suggestions, and follow-up investigations.

### Features

- **Streaming:** Both agents stream tokens via callbacks (`synthesisTokenCallback`, `hypothesesTokenCallback`), enabling real-time display.
- **Agent status:** A `statusCallback` reports which agent is currently running.
- **Configurable prompts:** Agent system prompts are loaded from `app_settings` with sensible defaults.
- **Role integration:** An optional user role prompt is prepended to each agent's system prompt for persona-based analysis.

### Result

```
DeepAnalysisResult
  synthesizedAnswer: String   // Engineer agent output with citations
  hypotheses: String          // Hypothesizer agent output
  analyzedAt: Date
```

Persisted to `query_history` columns: `synthesized_analysis`, `hypotheses`, `analyzed_at`.

---

## LLM Provider Integration

The system supports two LLM backends, configured independently for extraction, analysis, and embedding tasks.

### OllamaService (local inference)

- Wraps the `ollama-swift` client library.
- Methods: `chat()`, `chatStream()`, `embed()` (single and batch).
- Default timeout: 5 minutes.
- Used for both text generation and embedding generation.

### OpenRouterService (cloud inference)

- Built on SwiftAgents' `OpenRouterProvider`.
- Supports SSE-based token streaming via `chatStream()`.
- Default model: `meta-llama/llama-4-maverick`.
- Supported models include Meta Llama 4, OpenAI GPT-4.1/5.x families.
- Default max tokens: 8192 for longer extraction responses.

### LLMProvider Protocol

Both services conform to `LLMProvider` (defined in HyperGraphReasoning):

```swift
protocol LLMProvider {
    func chat(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        temperature: Double?
    ) async throws -> String
}
```

### Separate Configuration

The app maintains three independent LLM configurations:

| Purpose | Settings Keys | Fallback |
|---------|--------------|----------|
| **Extraction** (ingestion) | `llm_provider`, `ollama_endpoint`, `ollama_model`, `openrouter_key` | None (required) |
| **Analysis** (query + deep analysis) | `analysis_llm_provider`, `analysis_ollama_endpoint`, `analysis_openrouter_model` | Falls back to extraction LLM |
| **Embedding** | `embedding_provider`, `embedding_ollama_endpoint`, `embedding_ollama_model` | Ollama only |

Temperature is configurable per task: `extraction_temperature` and `analysis_temperature`.

---

## Node Management

### Similarity Search

`HypergraphService.searchSimilarConcepts(query:limit:)` embeds a text query and compares it against stored node embeddings using cosine distance to find related concepts.

### Node Merging

When the same concept appears under slightly different labels (e.g. "AWS" and "Amazon Web Services"), the system supports merging:

- `getMergeSuggestions(threshold:limit:)` — finds candidate pairs by embedding similarity.
- `mergeNodes(_:into:similarityScore:)` — rewires all incidences from the source node to the target, removes the source, and logs the merge in `node_merge_history`.

---

## Configuration Reference

All settings are stored in the `app_settings` table as key-value pairs.

| Category | Keys |
|----------|------|
| **LLM Provider** | `llm_provider`, `ollama_endpoint`, `ollama_model`, `openrouter_key`, `openrouter_model` |
| **Embedding** | `embedding_provider`, `embedding_ollama_endpoint`, `embedding_ollama_model`, `embedding_openrouter_model` |
| **Analysis LLM** | `analysis_llm_provider`, `analysis_ollama_endpoint`, `analysis_ollama_model`, `analysis_openrouter_model` |
| **Temperatures** | `extraction_temperature`, `analysis_temperature` |
| **Limits** | `max_concurrent_processing`, `max_path_depth`, `rag_max_nodes`, `rag_max_chunks` |
| **Custom Prompts** | `extraction_system_prompt`, `distillation_system_prompt`, `engineer_agent_prompt`, `hypothesizer_agent_prompt` |

---

## HyperGraphReasoning Package

The [HyperGraphReasoning](https://github.com/iliasaz/hypergraph-reasoning-swift) Swift package provides the core data structures and LLM integration used by the app:

| Export | Description |
|--------|-------------|
| `Hypergraph<NodeID, EdgeID>` | Generic hypergraph with incidence storage, adjacency caching, degree/neighbor queries |
| `HypergraphExtractor` | LLM-based SVO triple extraction from text chunks |
| `DocumentProcessor` | Full pipeline: text > chunks > extraction > embeddings |
| `OllamaService` | Local LLM provider with chat, streaming, and embedding |
| `OpenRouterService` | Cloud LLM provider with chat and SSE streaming |
| `EmbeddingService` | Batch embedding generation and similarity search |
| `NodeEmbeddings` | Container with cosine similarity operations |

The app layer (`HypergraphService`, `GraphRAGService`, `DeepAnalysisService`) handles persistence, UI integration, and the streaming query pipeline on top of this package.
