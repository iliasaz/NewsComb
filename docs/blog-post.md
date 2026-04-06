# From RSS Feed to Strategic Insights: Building a News Intelligence System

*How we implemented Knowledge Hypergraph, PCA, UMAP, and HDBSCAN from scratch in Swift, and what Apple Silicon's hardware taught us about algorithm design.*

---

## The Challenge

Imagine you work in an innovation team at a large tech company. Your job is to advise executive leadership on where to invest — which emerging technologies to bet on, which startup signals to amplify, which research breakthroughs are two years from production, and what the competitors are cooking up. You subscribe to 500+ RSS feeds across tech news, academic preprints, indie blogs, startup announcements and competitor news feeds.

The mainstream trends are easy: analyst firms cover them. The problem is analyzing the stuff that hasn't become the mainstream yet. Bleeding-edge research lives in papers nobody on the business side reads. Startup and indie signals are buried in noise — for every breakthrough, there are a hundred "we're disrupting X" announcements that lead nowhere.

What you need isn't another RSS reader or search engine. You need a system that reads everything, extracts structured knowledge while preserving cause-and-effect, finds hidden connections across unrelated sources, and answers in-depth questions like "what startups are working on the same problem this physics paper just described?".

This is the story of building that system. Over a several weekends, we went from a research paper to a macOS application that extracts knowledge graphs from news, clusters news events into themes, and uses causality knowledge to get deep insights on user questions.

---

## The Business Case: Technology Radar on Autopilot

Here's the concrete scenario. Your innovation team monitors three signal layers:

**Layer 1: Mainstream trends.** Well-covered by Gartner, Forrester, and the tech press and aggregators like TL;DR. You know about them. So does everyone else.

**Layer 2: Bleeding-edge research.** A materials science paper describes a new substrate for photonic computing. An MIT group publishes on neuromorphic architectures. These are high-signal but narrow audience.

**Layer 3: Startup and indie signals.** A YC company pivots to "AI inference at the edge." An indie developer open-sources a framework for federated fine-tuning. Most of these go nowhere, but the ones that succeed reshape markets. OpenClaw is a vivid example of this.

The value of a hypergraph-based system is in finding **convergence across layers**. When a physics paper, a startup pivot, and a customer feature request on your platform all point at the same capability gap — that's an investment signal. But no human can read 500 feeds and make those connections consistently.

A knowledge hypergraph can. The system ingests articles across all three layers, extracts entities and relationships, and builds a queryable graph. The reasoning paths explain *why* trends are connected: `photonic computing → enables → low-latency inference → required by → edge AI → demanded by → autonomous vehicles`. An analyst would need weeks to trace that chain. The graph does it in seconds.

Beyond individual connections, the system automatically **clusters thousands of events into themes**. The clustering pipeline groups semantically related events — "edge AI inference" emerges as a coherent theme from 40 articles across 15 feeds, spanning a research paper, three startup announcements, and a dozen industry analyses. These themes become an automated technology radar: each theme is a strategic signal, ranked by size and density, with representative articles and top entities surfaced for the analyst.

The real output: turning strategic awareness from an editorial process (humans reading and synthesizing) into a computational one (automated extraction, clustering, and reasoning).

---

## The Research Foundation

We built on the **HyperGraphRAG** framework (Buehler, 2025), which introduced hypergraph-driven reasoning with affordable LLM-based knowledge construction. The paper demonstrated that small language models can extract high-quality Subject-Verb-Object triples from text, and that hypergraph topology enables multi-hop reasoning that traditional RAG cannot. This section covers the core algorithmic ideas that make the system work.

### Why a Hypergraph?

The foundation matters. When we started, the natural question was: what data structure captures knowledge from news articles?

**Plain RAG** (Retrieval-Augmented Generation) chunks articles, embeds them, and retrieves relevant chunks at query time. It works for simple lookups but has no notion of entities, relationships, or reasoning paths. Ask "how are Apple and OpenAI connected?" and RAG searches for chunks containing both terms — it can't traverse a chain of relationships.

**Property graphs** (Neo4j-style) connect entities with typed edges. Better, but they have a fundamental limitation: each edge connects exactly two nodes. Consider the event "Apple, Google, and Samsung compete in the smartphone market." A binary graph needs three separate edges (Apple-Google, Apple-Samsung, Google-Samsung), losing the information that this was one event with one verb and three participants. Triple that across thousands of articles and you get a graph with inflated edge counts and diluted semantics.

**Hypergraphs** solve this. A hyperedge can connect any number of nodes. That competition event becomes a single hyperedge with three source nodes, one target node, and the relation "competes in." The semantic unit — the original event as extracted from the article — is preserved intact.

Our implementation extracts S-V-O triples from news articles using configurable LLMs (Meta Llama 4 Maverick via OpenRouter, or local models via Ollama). Each triple becomes a hyperedge in an incidence-based storage model: entities (nodes), relationships (edges), and participation records (which nodes play which roles — source, target, context — in which edges). The result: a knowledge graph where "Apple announces Vision Pro partnership with Unity and Adobe" is one event, not six binary edges.

The hypergraph structure directly enables **multi-hop reasoning**. When a user asks "what companies are investing in quantum computing?", the system doesn't just search for documents — it traverses the graph, following chains of relationships: `Company A → invests in → Startup B → develops → Technology C → based on → Research from Lab D`. Each hop is a real extracted event with provenance back to the source article. The answer is grounded in causal structure, not keyword matching.

### Embeddings and Graph Simplification

Raw extraction produces noise — the same entity appears under different names ("Google", "Alphabet", "Google DeepMind"). To handle this, every node gets a **vector embedding**: a 768-dimensional numerical representation of its meaning, computed by the Nomic Embed Text v1.5 model running on-device via Apple's MLX framework. Nodes whose embeddings are highly similar (cosine similarity above a configurable threshold) are automatically merged, collapsing duplicates while preserving all their relationships.

These embeddings serve double duty. Beyond graph simplification, they power **semantic search**: when a user asks a question, the query is embedded and compared against node embeddings to find relevant starting points in the graph. This combines the precision of graph traversal with the flexibility of vector similarity — you can find relevant nodes even when the exact terminology differs from what's in the graph.

We initially relied on an external Ollama process for embedding computation, but the bugs in Ollama’s implementation of Nomic embedding model and need to install a separate app made this option less favorable. Switching to on-device inference and running natively inside the application eliminated the dependency. After optimizing with batched GPU encoding (processing 64 texts per forward pass instead of one at a time), throughput went from 9 to 287 embeddings per second on an M5 — a 32x improvement.

### HDBSCAN: Finding Themes in the Noise

With tens of thousands of events extracted, the next challenge is organization. Which events belong together? What are the major themes?

We chose **HDBSCAN** (Hierarchical Density-Based Spatial Clustering of Applications with Noise) for this. The intuition is simple: **find the crowds, ignore the wanderers.** In a scatter plot, clusters are dense regions where points huddle together. Noise is the sparse no-man's-land between them.

Why HDBSCAN over alternatives? K-means requires you to specify the number of clusters upfront — but we don't know how many themes exist in today's news. It also forces every point into a cluster, even outliers. News themes aren't uniform: "AI chip competition" might involve 500 events while "quantum error correction" involves 20. K-means would either fragment the large cluster or absorb the small one. HDBSCAN handles varying cluster sizes, discovers the number of clusters automatically, and explicitly labels low-confidence points as noise rather than forcing them into ill-fitting groups.

The algorithm works by building a hierarchy of density levels. Imagine slowly raising the "sea level" across the scatter plot — dense islands emerge first, then merge as the water rises. HDBSCAN records this hierarchy and selects the most stable clusters: the ones that persist across the widest range of density thresholds.

### UMAP: The Manifold Hypothesis

HDBSCAN worked perfectly on test data. On real data at scale — 89K events in 2,316 dimensions — sometimes the clustering was subpar. Some clusters came out huge while others too small. The culprit: the **curse of dimensionality**. In 2,316 dimensions, every point is approximately equidistant from every other point. Density loses meaning when there are no meaningful density differences to detect.

The insight came from the topic modeling community. **BERTopic** and **Top2Vec** — the dominant approaches for clustering text embeddings — both use the same pipeline: reduce dimensions first, then cluster. PCA strips linear noise (2,316D down to 50D), then UMAP captures the nonlinear structure (50D down to 25D).

**UMAP** (Uniform Manifold Approximation and Projection) is built on a beautiful idea: **the manifold hypothesis.** Even though your vectors live in 2,316 dimensions, the *meaningful* structure — the patterns, the clusters, the relationships — lives on a much lower-dimensional surface embedded in that space. Think of a sheet of paper crumpled into a ball. The paper is 2D; the ball is 3D. UMAP finds the crumpled paper and flattens it back out — without tearing it.

More precisely: UMAP preserves **local neighborhoods.** Points that are close in the original space remain close in the reduced space. Global structure (which clusters are near which other clusters) is also preserved.

The implementation has three stages:

**Stage 1: Build a neighborhood graph.** For each of the 89K points, find its 15 nearest neighbors. This creates a sparse graph capturing local structure.

**Stage 2: Compute fuzzy membership strengths.** Not all neighbors are equally close. UMAP converts hard kNN relationships into soft membership weights using an exponential kernel, then symmetrizes the graph.

**Stage 3: Optimize a low-dimensional layout.** Starting from random positions in 25 dimensions, stochastic gradient descent iteratively adjusts the embedding. Connected points are pulled together; random non-neighbors are pushed apart. After 200 epochs, the 25D layout preserves the local structure of the original space.

### The Theme Generation Pipeline

These components come together in an end-to-end pipeline that transforms raw hypergraph events into labeled story themes:

1. **Event vector construction.** Each hyperedge becomes a dense vector by pooling the embeddings of its participant nodes, weighted by IDF (Inverse Document Frequency — hub entities like "AI" or "cloud" are down-weighted so they don't dominate). The source embeddings, target embeddings, a directional difference vector, and a relation family one-hot encoding are concatenated into a 2,316-dimensional event vector.

2. **PCA pre-reduction.** Linear projection strips noise dimensions: 2,316D down to 50D, retaining the principal components that explain the most variance.

3. **UMAP manifold learning.** Nonlinear reduction from 50D to 25D, preserving local neighborhood structure while collapsing the space to a dimension where density is meaningful.

4. **HDBSCAN clustering.** Density-based clustering on the 25D embedding discovers themes automatically — no predefined number of clusters, no forcing outliers into groups.

5. **Cluster enrichment.** For each cluster, the system computes a centroid, identifies top entities by IDF-weighted frequency, selects exemplar events (closest to centroid), and generates an auto-label. Optionally, an LLM reads the exemplar sentences and produces a human-readable headline and summary for each theme.

6. **Post-processing.** Similar clusters (centroid cosine similarity above 0.85) are merged to consolidate fragmented themes.

The pipeline is triggered by a single button press and runs with progressive status updates.

---

## User Experience

### Visual Exploration

An interactive force-directed graph visualization lets users pan, zoom, and expand node neighborhoods. Double-tap a node to reveal its connections; single-tap for details. The physics-based layout naturally clusters related entities, giving users an intuitive spatial sense of the knowledge landscape — before any formal clustering algorithm runs.

### Conversational Querying and In-Depth Reports

A knowledge graph you can't query is just a database. When a user asks "what companies are investing in quantum computing?", an AI agent executes a six-phase pipeline: extract keywords, embed them, search for related nodes via cosine similarity, discover multi-hop reasoning paths via BFS, gather context from article provenance, and stream a grounded answer.

The answers include reasoning paths — causal chains like:

```
NVIDIA → competes with → AMD → partners with → Microsoft → invests in → OpenAI
```

These paths are traversed from the actual graph structure, not hallucinated. The key distinction from vanilla LLM chat: every claim is grounded in the causality captured by the graph.

**In-depth reports.** "Dive Deeper" triggers a multi-agent workflow: an Engineer agent synthesizes findings with academic-style citations (`[1]`, `[2]`), and a Hypothesizer agent generates follow-up research questions and experiment suggestions. This turns a simple query into a 2-3 page analysis that an innovation team can present to leadership.

### Story Themes

The clustering pipeline produces a thematic overview: each theme gets an auto-generated label (top entities + dominant relationship type), a size indicator, and optionally an LLM-generated headline and summary. Users browse themes like a news digest — "AI Chip Competition (342 events)", "Quantum Computing Investment (87 events)" — and drill into any theme to see its top entities, exemplar events, and relationship distribution.

---

## The Performance Journey

Implementing the algorithms was the straightforward part. Making them run at the scale of 89K events was the real engineering challenge. Each bottleneck led to a deeper understanding of both the algorithms and the hardware.

**PCA: 2,316D to 50D in 3.6 seconds.** The covariance matrix computation was the first target. The naive approach requires allocating a large intermediate array (89K x 2316 x 4 bytes = 790 MB). We replaced this with a BLAS symmetric rank-k update, which computes the covariance directly from the data without the intermediate allocation.

**UMAP kNN: The VP-tree lie.** Vantage-Point trees are the textbook answer for nearest-neighbor search — sublinear query time in theory. In practice, at 50 dimensions, VP-trees prune poorly. Most branches get visited because all distances converge. Our parallel VP-tree (queries distributed across all CPU cores) still took 15 minutes.

The fix: brute-force matrix multiply via Apple's Accelerate framework. For normalized vectors, cosine similarity equals the dot product. We compute the similarity matrix in tiles, then extract top-k per row in parallel. The key: `vDSP_mmul` routes to Apple Silicon's **AMX coprocessor** — a dedicated matrix multiply unit. An 89K x 50 multiply completes in ~100 milliseconds. Total: 75 seconds, down from 15 minutes.

**UMAP SGD: 1.4 billion `pow` calls.** The SGD inner loop computes `pow(distSq, b)` for every edge at every epoch — 1.4 billion calls. We replaced all per-dimension scalar loops with vectorized operations and substituted the expensive `pow` with a fast single-precision approximation (`exp(b * log(x))`). Total: 144 seconds for 200 epochs, down from ~600.

**HDBSCAN: From 128 GB to 15 MB.** The original implementation computed a full N x N distance matrix. At N=89K, four intermediate arrays totaled 128 GB — it crashed the machine. The fix: reuse the kNN graph from UMAP. HDBSCAN needs core distances and a minimum spanning tree, both derivable from the sparse kNN graph. Memory: 15 MB instead of 128 GB. Same algorithm, same results.

### Leveraging Apple Silicon

Every optimization above maps to a specific hardware feature of Apple Silicon:

| Pipeline Stage | Hardware Feature | Why It Wins |
|---------------|------------------|-------------|
| PCA (covariance matrix) | **AMX coprocessor** | Hardware-accelerated matrix multiply |
| UMAP kNN (similarity matrix) | **AMX coprocessor** | Tiled N x N dot products at hardware speed |
| UMAP SGD (gradient updates) | **NEON SIMD** | Vectorized operations on 128-bit lanes |
| Nomic embeddings | **GPU** | Batched transformer inference via MLTensor |
| All stages | **Unified Memory** | CPU, GPU, and Neural Engine share physical RAM — zero-copy |

The insight: **on Apple Silicon, algorithms that express work as matrix operations beat algorithms with better asymptotic complexity but branch-heavy execution.** VP-trees are O(N log N); brute-force matrix multiply is O(N^2 D). But the AMX coprocessor makes the constant factor irrelevant at realistic data sizes.

---

## The Full Pipeline

Here's what happens when a user clicks "Recompute Themes" with 89K events on an M5 MacBook Pro:

| Stage | Time | Memory |
|-------|------|--------|
| IDF weights + event vectors | ~30s | ~200 MB |
| PCA: 2,316D to 50D | 3.6s | ~800 MB peak |
| UMAP kNN: 50D, k=15 | 75s | ~1.5 GB per tile |
| UMAP SGD: 200 epochs | 144s | ~9 MB |
| HDBSCAN (sparse) | ~30s | ~15 MB |
| Cluster artifacts + LLM labeling | ~60s | Minimal |
| **Total** | **~6 minutes** | **~2 GB peak** |

Every stage can be skipped or reconfigured independently.

---

## Lessons Learned

**1. Automated knowledge graphs lower the cost of strategic awareness.** The value isn't the technology — it's replacing a human editorial process (people reading and synthesizing) with a computational one. The system reads 500 feeds so the innovation team doesn't have to.

**2. Know your hardware before choosing your algorithm.** VP-trees are theoretically optimal for kNN. On Apple Silicon with AMX, brute-force matrix multiply is faster. The best algorithm depends on what silicon you have.

**3. Dimensionality reduction is not optional for embedding clustering.** HDBSCAN on raw 2,316-dim vectors produced garbage. After PCA + UMAP to 25 dimensions, the same algorithm found clean, interpretable clusters. The BERTopic pipeline (PCA, UMAP, HDBSCAN) is the right default.

**4. Sparse representations save orders of magnitude in memory.** The HDBSCAN distance matrix needed 128 GB. The sparse kNN graph needed 15 MB. Same results. When you see an O(N^2) data structure, ask whether the algorithm actually *uses* all N^2 entries.

**5. Batch at the hardware level, not the concurrency level.** Concurrent GPU tasks crashed the Metal runtime. One serialized queue with batched GPU encoding gave 32x throughput without concurrency bugs.

**6. Start with the naive implementation, measure, then optimize.** Every optimization in this project started with a correct-but-slow implementation and a profiler trace. We never optimized something that wasn't measured first.

**7. Local-first is a feature, not a compromise.** On-device embeddings, on-device clustering, on-device graph traversal. No API keys required for core functionality. The privacy and reliability wins are real.

---

## Side Experiment: Social Simulation and the Social Graph

While the clustering pipeline was our main technical challenge, we ran a speculative side experiment that points to a different future for knowledge graphs.

The question: **what if the entities in the graph could *behave*?**

We integrated **OASIS** (Open-Ended Autonomous Simulation System), an agent-based modeling framework, to turn knowledge graph entities into social media agents. The pipeline:

1. **Entity classification.** An LLM labels each node as Person, Company, Technology, Regulatory Body, etc.
2. **Persona generation.** For each entity, the LLM creates a personality profile — MBTI type, sentiment bias, interests, influence weight — grounded in the entity's graph context (what events it participates in, who it's connected to).
3. **Social graph construction.** The hypergraph's competition, partnership, and investment edges become follower/followee relationships between agents.
4. **Agent-based simulation.** OASIS runs agents who post, comment, repost, and form groups — all based on their personas and the events they're connected to in the knowledge graph.
5. **Action ingestion.** Agent behavior is captured back into the database as social posts, interactions, and group dynamics — creating a synthetic social graph layered on top of the knowledge graph.

What this gives you: not just "these are the trends" but "here's how the ecosystem *might react* to a disruption." Simulate a supply chain shock and watch how competitor agents, partner agents, and regulator agents respond. See which agents amplify the signal, which form defensive coalitions, which pivot.

This is still experimental — a side experiment alongside the main clustering work. But it points to a future where knowledge graphs aren't just static repositories of extracted facts but **dynamic world models** that can simulate emergent behavior. The difference between a map and a war game.

---

## What's Next

Three directions:

**GPU-accelerated UMAP via MLX Swift.** The SGD loop is the remaining CPU bottleneck. MLX Swift (Apple's ML framework with Swift bindings) could move the entire gradient computation to GPU metal shaders, potentially achieving 10-50x speedup. A reference implementation exists in Python (hanxiao/mlx-vis).

**Incremental clustering.** Currently the full pipeline reruns from scratch. Incremental UMAP and HDBSCAN on new events — updating the embedding and cluster assignments without recomputing from zero — would make the system live-updating.

**Deeper simulation integration.** Using clustering results to seed simulation scenarios: when a new theme emerges, automatically simulate how the ecosystem responds. Closing the loop from detection to prediction.

---

## References

- Buehler, M.J. (2025). "HyperGraphRAG: Hypergraph-Driven Reasoning and Affordable LLM-Based Knowledge Construction." arXiv:2601.04878.
- McInnes, L., Healy, J., & Melville, J. (2018). "UMAP: Uniform Manifold Approximation and Projection for Dimension Reduction." arXiv:1802.03426.
- Grootendorst, M. (2022). "BERTopic: Neural topic modeling with a class-based TF-IDF procedure."
- Campello, R.J.G.B., Moulavi, D., & Sander, J. (2013). "Density-Based Clustering Based on Hierarchical Density Estimates." PAKDD 2013.
- Apple Inc. "Accelerate Framework: vDSP, BLAS, LAPACK." developer.apple.com.

---

*NewsComb is an open-source project. The complete source code, including the pure-Swift PCA, UMAP, and HDBSCAN implementations, is available on GitHub.*
