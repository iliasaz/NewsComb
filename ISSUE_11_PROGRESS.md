# Issue #11: Story Theme Clustering with HDBSCAN

## Progress Tracker

### Step 0 — Database Schema & Models
- [x] Add `df`, `idf` columns to `hypergraph_node` via migration
- [x] Create `event_vectors` table (sqlite-vec, float[2316])
- [x] Create `clusters` table
- [x] Create `cluster_members` table
- [x] Create `event_cluster` table
- [x] Create `cluster_exemplars` table
- [x] Create GRDB model structs (`StoryCluster`, `EventCluster`, `ClusterMember`, `ClusterExemplar`)
- [x] Create `RelationFamily` enum with verb classification

### Step 1 — Node DF/IDF Weights
- [x] Implement DF computation (count events per node)
- [x] Implement IDF computation with clamping (idfMax = 6.0)
- [x] Persist to `hypergraph_node.df` / `hypergraph_node.idf`

### Step 2 — Event Vector Construction
- [x] Implement relation family bucketing (verb -> family mapping, 12 families)
- [x] Implement IDF-weighted node embedding pooling (source vec, target vec, diff vec)
- [x] Concatenate into final event vector (dim = 2316) and persist to `event_vectors`

### Step 3 — HDBSCAN Clustering
- [x] Implement distance matrix computation (Euclidean via Accelerate/BLAS)
- [x] Implement core distance computation (k-NN)
- [x] Implement mutual reachability graph
- [x] Implement minimum spanning tree (Prim's algorithm)
- [x] Implement condensed cluster tree
- [x] Implement EOM cluster selection
- [x] Return cluster labels and membership scores

### Step 4 — Cluster Artifacts
- [x] Persist cluster assignments (`event_cluster`, `cluster_members`)
- [x] Compute and persist cluster centroids (mean + normalize via Accelerate)
- [x] Compute top entities per cluster (IDF-weighted frequency)
- [x] Select and persist exemplar events (top-10 by cosine similarity to centroid)
- [x] Auto-label clusters (`"<Entity1>, <Entity2> — <RelFamily>"`)

### Step 5 — UI Integration
- [x] Create `ThemeClusterViewModel` (load clusters, rebuild pipeline)
- [x] Create `ThemeDetailViewModel` (exemplars, full member list)
- [x] Create `ThemesView` (themes list with stats, rebuild button, progress)
- [x] Create `ThemeDetailView` (overview, top entities, exemplars, all members)
- [x] Add navigation in `MainView` (Story Themes section + navigation destinations)
- [x] Add "Recompute Themes" action with progress display

### Step 6 — Build & Verify
- [x] Full build succeeds (BUILD SUCCEEDED, 0 warnings in new files)
- [ ] End-to-end pipeline runs without errors

## Files Created/Modified

### New Files (10)
| File | Purpose |
|------|---------|
| `Models/StoryCluster.swift` | Cluster model + RankedEntity/RankedFamily |
| `Models/EventCluster.swift` | EventCluster, ClusterMember, ClusterExemplar models |
| `Models/RelationFamily.swift` | 12-family verb classifier with one-hot encoding |
| `Services/EventVectorService.swift` | IDF computation + event vector construction |
| `Services/HDBSCANService.swift` | Pure-Swift HDBSCAN implementation |
| `Services/ClusteringService.swift` | Pipeline orchestrator + artifact builder |
| `ViewModels/ThemeClusterViewModel.swift` | Themes list VM with rebuild support |
| `ViewModels/ThemeDetailViewModel.swift` | Theme detail VM with event display |
| `Views/ThemesView.swift` | Themes list UI |
| `Views/ThemeDetailView.swift` | Theme detail UI |

### Modified Files (3)
| File | Change |
|------|--------|
| `Services/DatabaseService.swift` | Added df/idf columns + 4 new tables |
| `Models/HypergraphNode.swift` | Added df/idf properties and column mappings |
| `Views/MainView.swift` | Added Story Themes section + navigation destinations |
