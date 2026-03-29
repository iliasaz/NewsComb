# Story Theme Clustering

This document describes the story theme clustering subsystem, which groups related news events (hyperedges) into coherent themes using a **PCA → UMAP → HDBSCAN** pipeline. Dimensionality reduction via PCA and UMAP addresses the curse of dimensionality in the 2,316-dim event vector space, producing tighter and more coherent clusters. The system produces human-readable titles and summaries for each theme via optional LLM enrichment.

---

## Architecture Overview

```
Hypergraph Edges (events)
    |
    v
EventVectorService
    |
    ├── Computes node DF/IDF weights
    |
    ├── Pools source/target node embeddings per event
    |       weighted by IDF, concatenated with relation family one-hot
    |
    └── Persists event vectors to SQLite vec0 table
    |
    v
PCAService (Accelerate LAPACK)             ── 2,316D → 50D linear reduction
    |
    v
UMAPService (pure-Swift)                   ── 50D → 25D nonlinear manifold learning
    |
    ├── VP-tree kNN graph construction
    ├── Fuzzy simplicial set (membership weights)
    └── SGD layout optimization
    |
    v
HDBSCANService (pure-Swift, uses Accelerate)
    |
    ├── Pairwise cosine distance matrix
    ├── Core distances (k-th nearest neighbor)
    ├── Minimum spanning tree (Prim's on mutual reachability graph)
    ├── Condensed cluster tree
    └── Excess of Mass (EOM) cluster selection
    |
    v
ClusteringService (pipeline orchestrator)
    |
    ├── Persists cluster assignments, centroids, top entities, exemplars
    ├── Generates auto-labels: "<Entity1>, <Entity2> -- <RelationFamily>"
    |
    └── ClusterLabelingService (optional LLM enrichment)
            |
            ├── Loads exemplar S-V-O sentences per cluster
            ├── Calls analysis LLM with news-editor prompt
            ├── Parses JSON response: {"title": "...", "summary": "..."}
            └── Overwrites auto-label with LLM title, persists summary
```

---

## Pipeline Steps

The full pipeline is orchestrated by `ClusteringService.runFullPipeline()` and triggered from the UI via the Themes tab "Recompute" button.

### Step 1: Compute IDF Weights

`EventVectorService.computeIDFWeights()` calculates document frequency and inverse document frequency for every node in the hypergraph. High-frequency hub nodes (e.g., "AI", "cloud") are down-weighted so they don't dominate the event vectors.

- `df` = number of distinct edges a node participates in
- `idf = log((N + 1) / (df + 1)) + 1` where N = total edge count

### Step 2: Build Event Vectors

`EventVectorService.buildEventVectors()` constructs a dense vector for each hyperedge by:

1. **Pooling node embeddings**: For each event's source and target nodes, compute the IDF-weighted mean of their embedding vectors.
2. **Directional diff**: `diff = normalize(targetVec - sourceVec)` captures the semantic direction of the relationship.
3. **Relation family one-hot**: The edge's verb is classified into one of 12 `RelationFamily` buckets (e.g., Competition, Partnership, Regulation) and encoded as a one-hot vector.
4. **Concatenation**: `eventVec = [sourceVec | targetVec | diff | familyOneHot]` with dimension `3d + 12` where `d` is the embedding dimension.

Vectors are stored in the `event_vectors` vec0 virtual table.

### Step 3: PCA Dimensionality Reduction

`PCAService.project()` reduces event vectors from 2,316 dimensions to an intermediate dimension (default 50) using principal component analysis:

1. **Mean-center** the data matrix.
2. **Covariance matrix**: Compute D×D covariance via `vDSP_mmul` (Accelerate matrix multiply).
3. **Eigendecompose**: LAPACK `ssyev_` computes eigenvectors and eigenvalues of the symmetric covariance matrix.
4. **Project**: Multiply centered data by the top-k eigenvectors.

This linear pre-reduction removes noise dimensions and makes the subsequent UMAP kNN search tractable (VP-trees degrade in very high dimensions).

**Performance**: Sub-second for any N (the bottleneck is the D×D eigendecomposition, not N-dependent). Default: 2,316D → 50D.

### Step 4: UMAP Nonlinear Embedding

`UMAPService.reduce()` learns a nonlinear low-dimensional embedding that preserves local neighborhood structure:

1. **kNN graph**: VP-tree (`VPTreeService`) finds k-nearest neighbors for each point using cosine distance. Runs in O(N log N) at 50 dimensions.
2. **Fuzzy simplicial set**: Converts kNN distances to membership weights via per-point bandwidth σ (found by binary search) and symmetrizes the graph via fuzzy union.
3. **SGD layout**: Stochastic gradient descent optimizes the low-dimensional embedding using attractive forces (pull connected points together) and repulsive forces (push random non-neighbors apart via negative sampling).

Default parameters: `nNeighbors = 15`, `targetDimension = 25`, `minDist = 0.1`, `nEpochs = 200`.

**Performance**: ~6-14 seconds for N=50K on M-series chips (kNN dominates at ~2-5s).

### Step 5: HDBSCAN Clustering

`HDBSCANService.cluster()` implements the full HDBSCAN algorithm in pure Swift using Accelerate for distance computations. With UMAP pre-reduction, HDBSCAN operates on ~25D vectors instead of 2,316D:

1. **Distance matrix**: Full N x N cosine distance matrix via `vDSP_mmul`.
2. **Core distances**: k-th nearest neighbor distance per point (k = `minSamples`).
3. **Mutual reachability graph**: `mr(a,b) = max(core(a), core(b), dist(a,b))`.
4. **Minimum spanning tree**: Prim's algorithm on the mutual reachability graph.
5. **Condensed cluster tree**: Collapses chains of small-child merges, recording only "real splits" where both children meet `minClusterSize`.
6. **EOM selection**: Bottom-up Excess of Mass selects the most stable clusters.

Default parameters: `minClusterSize = 20`, `minSamples = 10`, metric = cosine.

### Step 6: Persist Assignments

Cluster assignments are written to `event_cluster` (every event, including noise as cluster -1) and `cluster_members` (non-noise only).

### Step 7: Build Cluster Artifacts

For each cluster:
- **Centroid**: Mean of member event vectors (L2-normalized).
- **Top entities**: Node labels ranked by IDF-weighted frequency across member events (top 20).
- **Top relation families**: Relation family distribution (top 5).
- **Exemplars**: Top 10 events by cosine similarity to the centroid.
- **Auto-label**: `"<Entity1>, <Entity2> -- <TopFamily>"`.

### Step 8: LLM-Generated Titles and Summaries (Optional)

`ClusterLabelingService.labelClusters()` enriches clusters with human-readable headlines and summaries by calling the configured analysis LLM. When no LLM is configured, auto-labels are preserved.

**Per cluster:**
1. Load exemplar S-V-O sentences via SQL join across `cluster_exemplars`, `hypergraph_edge`, `hypergraph_incidence`, and `hypergraph_node`.
2. Build a prompt with top 10 entities, top 5 relation families, and up to 8 exemplar sentences.
3. Call the analysis LLM (Ollama or OpenRouter) with a news-editor system prompt.
4. Parse the JSON response (`{"title": "...", "summary": "..."}`), stripping markdown code fences if present.
5. Update the cluster's `label` and `summary` columns.

**Error handling**: Per-cluster errors are caught individually. If the LLM fails for one cluster (timeout, bad JSON, etc.), the auto-label is preserved and the pipeline continues to the next cluster.

---

## Configuration Parameters

The following dimensionality reduction and clustering parameters are configurable via Settings → Algorithm Parameters:

| Parameter | Key | Default | Description |
|-----------|-----|---------|-------------|
| PCA Intermediate Dim | `pca_intermediate_dimension` | 50 | Target dimension for PCA pre-reduction. Higher values preserve more variance but slow kNN. |
| UMAP Target Dim | `umap_target_dimension` | 25 | Target dimension for UMAP embedding. 15-30 is typical for clustering. |
| UMAP Neighbors | `umap_n_neighbors` | 15 | Controls how UMAP balances local vs. global structure. Lower values = more local detail. |
| Min Cluster Size | (hardcoded) | 20 | Minimum events to form a cluster. Dynamically scaled: `max(20, sqrt(N)/2)`. |
| Min Samples | (hardcoded) | 10 | Core distance neighborhood size for HDBSCAN. |
| Distance Metric | (hardcoded) | cosine | HDBSCAN distance metric. Cosine is preferred for normalized embedding vectors. |

Both PCA and UMAP steps are automatically skipped when the input dimension is already at or below the target (e.g., for small embedding models).

---

## Database Tables

### `clusters`

Cluster definitions with centroids, metadata, and optional LLM-generated summaries.

| Column | Type | Notes |
|--------|------|-------|
| `cluster_id` | INTEGER PK | Cluster identifier from HDBSCAN |
| `build_id` | TEXT | Groups clusters from the same pipeline run |
| `label` | TEXT | Display name (auto-generated, overwritten by LLM if available) |
| `size` | INTEGER | Number of member events |
| `centroid_vec` | BLOB | L2-normalized mean event vector |
| `top_entities_json` | TEXT | JSON array of `{label, score}` objects (top 20) |
| `top_rel_families_json` | TEXT | JSON array of `{family, count}` objects (top 5) |
| `summary` | TEXT | LLM-generated 1-paragraph summary (nullable) |
| `created_at` | REAL | Unix epoch timestamp |

**Indexes:** `idx_clusters_build(build_id)`

### `event_cluster`

Maps every event (edge) to its cluster assignment for a given build. Noise events have `cluster_id = -1`.

| Column | Type | Notes |
|--------|------|-------|
| `event_id` | INTEGER PK | References `hypergraph_edge(id)` |
| `build_id` | TEXT | Clustering build identifier |
| `cluster_id` | INTEGER | Assigned cluster (-1 = noise) |
| `membership` | REAL | Membership strength (0..1) |

**Indexes:** `idx_event_cluster_build(build_id)`, `idx_event_cluster_cluster(cluster_id)`

### `cluster_members`

Non-noise cluster members for quick lookups.

| Column | Type | Notes |
|--------|------|-------|
| `cluster_id` | INTEGER | FK to `clusters(cluster_id)` ON DELETE CASCADE |
| `event_id` | INTEGER | References `hypergraph_edge(id)` |
| `membership` | REAL | Membership strength |

**Primary key:** `(cluster_id, event_id)`

### `cluster_exemplars`

Top exemplar events per cluster, ranked by cosine similarity to the centroid.

| Column | Type | Notes |
|--------|------|-------|
| `cluster_id` | INTEGER | FK to `clusters(cluster_id)` ON DELETE CASCADE |
| `event_id` | INTEGER | References `hypergraph_edge(id)` |
| `rank` | INTEGER | 0 = closest to centroid |

**Primary key:** `(cluster_id, rank)`

### `event_vectors` (vec0 virtual table)

Dense event vectors for clustering, stored via the sqlite-vec extension.

| Column | Type | Notes |
|--------|------|-------|
| `event_id` | INTEGER PK | References `hypergraph_edge(id)` |
| `vec` | float[D] | D = `3 * embedding_dim + 12` |

---

## Deletion Order

When clearing clustering data, tables must be deleted in this order to respect foreign key constraints:

```
cluster_exemplars   (FK → clusters)
cluster_members     (FK → clusters)
event_cluster       (no FK, but logically depends on clusters)
clusters            (parent table)
event_vectors       (vec0 virtual table, no FK)
```

Both `clearAllArticles()` and `resetKnowledgeGraph()` in `MainViewModel` follow this order.

---

## Key Files

| File | Purpose |
|------|---------|
| `Services/EventVectorService.swift` | IDF computation and event vector construction |
| `Services/PCAService.swift` | PCA via Accelerate LAPACK (linear reduction) |
| `Services/VPTreeService.swift` | Vantage-Point tree for kNN search |
| `Services/UMAPService.swift` | UMAP nonlinear dimensionality reduction |
| `Services/HDBSCANService.swift` | Pure-Swift HDBSCAN with Accelerate |
| `Services/ClusteringService.swift` | Pipeline orchestrator (steps 1-8) |
| `Services/ClusterLabelingService.swift` | LLM title and summary generation |
| `Models/StoryCluster.swift` | GRDB model for the `clusters` table |
| `Models/EventCluster.swift` | GRDB model for the `event_cluster` table |
| `Models/RelationFamily.swift` | Verb-to-family classification (12 buckets) |
| `ViewModels/ThemeClusterViewModel.swift` | Drives the themes list view |
| `ViewModels/ThemeDetailViewModel.swift` | Drives the theme detail view |
| `Views/ThemesView.swift` | Themes list with cluster rows and summaries |
| `Views/ThemeDetailView.swift` | Detail view with overview, entities, exemplars |
