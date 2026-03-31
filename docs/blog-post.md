# From RSS Feed to Knowledge Graph: Building a Privacy-Preserving News Intelligence System in Pure Swift

*How we implemented PCA, UMAP, and HDBSCAN from scratch in Swift, and what Apple Silicon's hardware taught us about algorithm design.*

---

## The Challenge

Imagine you lead an innovation team at a large cloud provider. Your job is to advise executive leadership on where to invest — which emerging technologies to bet on, which startup signals to amplify, which research breakthroughs are two years from production. You subscribe to 500+ RSS feeds across tech news, academic preprints, indie blogs, and startup announcements.

The mainstream trends are easy: analyst firms cover them. The problem is the other two layers. Bleeding-edge research lives in papers nobody on the business side reads. Startup and indie signals are buried in noise — for every breakthrough, there are a hundred "we're disrupting X" announcements that lead nowhere.

What you need isn't another RSS reader or search engine. You need a system that reads everything, extracts structured knowledge, finds hidden connections across unrelated sources, and lets you ask questions like "what startups are working on the same problem this physics paper just described?" — all running locally on your laptop, with no data leaving the device.

This is the story of building that system. Over eleven weeks and 147 commits, we went from a research paper to a production macOS application that extracts knowledge graphs from news, clusters events into themes, and answers multi-hop reasoning questions — with a pure-Swift PCA-UMAP-HDBSCAN pipeline optimized for Apple Silicon.

---

## Why a Hypergraph?

The foundation matters. When we started, the natural question was: what data structure captures knowledge from news articles?

**Plain RAG** (Retrieval-Augmented Generation) chunks articles, embeds them, and retrieves relevant chunks at query time. It works for simple lookups but has no notion of entities, relationships, or reasoning paths. Ask "how are Apple and OpenAI connected?" and RAG searches for chunks containing both terms — it can't traverse a chain of relationships.

**Property graphs** (Neo4j-style) connect entities with typed edges. Better, but they have a fundamental limitation: each edge connects exactly two nodes. Consider the event "Apple, Google, and Samsung compete in the smartphone market." A binary graph needs three separate edges (Apple-Google, Apple-Samsung, Google-Samsung), losing the information that this was one event with one verb and three participants. Triple that across thousands of articles and you get a graph with inflated edge counts and diluted semantics.

**Hypergraphs** solve this. A hyperedge can connect any number of nodes. That competition event becomes a single hyperedge with three source nodes, one target node, and the relation "competes in." The semantic unit — the original event as extracted from the article — is preserved intact.

We built on the **HyperGraphRAG** framework (Buehler, 2025), which introduced hypergraph-driven reasoning with affordable LLM-based knowledge construction. The paper demonstrated that small language models can extract high-quality Subject-Verb-Object triples from text, and that hypergraph topology enables multi-hop reasoning that traditional RAG cannot.

Our Swift implementation extracts these S-V-O triples from news articles using configurable LLMs (Meta Llama 4 Maverick via OpenRouter, or local models via Ollama). Each triple becomes a hyperedge in an incidence-based storage model: `hypergraph_node` (entities), `hypergraph_edge` (relationships), and `hypergraph_incidence` (which nodes participate in which edges, with roles like source, target, and context).

The result: a knowledge graph where "Apple announces Vision Pro partnership with Unity and Adobe" is one event, not six binary edges.

---

## The Business Case: Technology Radar on Autopilot

Here's the concrete scenario. Your innovation team monitors three signal layers:

**Layer 1: Mainstream trends.** Well-covered by Gartner, Forrester, and the tech press. You know about them. So does everyone else.

**Layer 2: Bleeding-edge research.** A materials science paper describes a new substrate for photonic computing. An MIT group publishes on neuromorphic architectures. These are high-signal but buried in venues your product managers don't read.

**Layer 3: Startup and indie signals.** A YC company pivots to "AI inference at the edge." An indie developer open-sources a framework for federated fine-tuning. Most of these go nowhere, but the ones that succeed reshape markets.

The value of a hypergraph-based system is in finding **convergence across layers**. When a physics paper, a startup pivot, and a customer feature request on your platform all point at the same capability gap — that's an investment signal. But no human can read 500 feeds and make those connections consistently.

A knowledge hypergraph can. The system ingests articles across all three layers, extracts entities and relationships, and builds a queryable graph. The clustering pipeline (which we'll get to) automatically groups related events into themes — "edge AI inference" emerges from 40 articles across 15 feeds, spanning a research paper, three startup announcements, and a dozen industry analyses.

The reasoning paths explain *why* trends are connected: `photonic computing → enables → low-latency inference → required by → edge AI → demanded by → autonomous vehicles`. An analyst would need weeks to trace that chain. The graph does it in seconds.

The real output: turning strategic awareness from an editorial process (humans reading and synthesizing) into a computational one (automated extraction, clustering, and reasoning).

---

## The Research Foundation

We chose Swift 6.2 with its "approachable concurrency" model (main actor by default, explicit `@concurrent` for parallelism) and GRDB.swift for SQLite persistence. The decision against SwiftData was deliberate: we needed FTS5 full-text indexing, sqlite-vec virtual tables for embedding vectors, and raw SQL for complex joins across provenance chains. No ORM handles that gracefully.

The local-first design was a hard requirement. Embeddings are stored in sqlite-vec virtual tables — no Pinecone, no Weaviate, no external vector database. The entire knowledge graph, embeddings included, lives in a single SQLite file on the user's machine.

---

## Exploring and Reasoning Over the Graph

A knowledge graph you can't explore is just a database. We built three interaction modes:

**Visual exploration.** An interactive force-directed graph visualization where users pan, zoom, and expand node neighborhoods. Double-tap a node to reveal its connections; single-tap for details. The physics-based layout naturally clusters related entities, giving users an intuitive spatial sense of the knowledge landscape.

**Conversational querying.** Ask "what companies are investing in quantum computing?" and an AI agent executes a six-phase pipeline: extract keywords, embed them, search for related nodes via cosine similarity, discover multi-hop reasoning paths via BFS, gather context from article provenance, and stream a grounded answer.

The answers include reasoning paths — causal chains like:

```
NVIDIA → competes with → AMD → partners with → Microsoft → invests in → OpenAI
```

These paths are traversed from the actual graph structure, not hallucinated. The BFS that discovers them was a performance story of its own: our initial pairwise approach did 45 separate traversals for 10 related nodes. A multi-source BFS reduced this to a single traversal — a 10x speedup from the same graph, same query, better algorithm.

**In-depth reports.** "Dive Deeper" triggers a multi-agent workflow: an Engineer agent synthesizes findings with academic-style citations (`[1]`, `[2]`), and a Hypothesizer agent generates follow-up research questions and experiment suggestions. The key distinction from vanilla LLM chat: every claim is grounded in the causality captured by the graph, not in the model's training data.

---

## The Embedding Problem

Our first external dependency became our biggest reliability problem. We initially used Ollama running locally for embeddings — a 768-dimensional Nomic Embed Text model. But Ollama is a separate process: flaky connection detection, users needing to install and run it, race conditions when multiple articles tried to embed concurrently.

We switched to **on-device inference** via the `swift-embeddings` library and Apple's MLTensor framework. The same Nomic Embed Text v1.5 model, but running natively inside the app. No external process, no network calls, no data leaving the device.

The GPU presented its own challenge. Concurrent `bundle.encode()` calls crashed Apple's Metal runtime (MPSGraph/SDPA conflicts). The fix: we converted `NomicEmbeddingService` to a Swift actor with a continuation-based queue — one encode at a time, callers queue up automatically. Serial, but safe.

Then we recovered the throughput through **batch encoding**. Instead of encoding texts one at a time (9 embeddings/second), we batch them into groups of 64 using the library's `batchEncode` API — shared padding, shared attention masks, one GPU forward pass. Result: 287 embeddings per second on an M5. A 32x improvement, and we benchmarked the optimal batch size empirically (throughput plateaus at 64 on M5; beyond that, padding waste exceeds parallelism gains).

---

## The Clustering Challenge: Why 2,316 Dimensions Break Everything

With 89,000 events extracted from thousands of articles, we needed to cluster them into coherent themes. Each event is represented as a 2,316-dimensional vector: three 768-dimensional embeddings (source entities, target entities, directional difference) plus a 12-dimensional relation family one-hot encoding.

We implemented HDBSCAN — Hierarchical Density-Based Spatial Clustering of Applications with Noise. The intuition is simple: **find the crowds, ignore the wanderers.** In a scatter plot, clusters are dense regions where points huddle together. Noise is the sparse no-man's-land between them. Unlike K-means, HDBSCAN doesn't require you to specify the number of clusters upfront, handles clusters of different sizes and densities, and explicitly labels outliers as noise rather than forcing them into a cluster.

We chose HDBSCAN over K-means for exactly these properties. News themes aren't uniform: "AI chip competition" might involve 500 events while "quantum error correction" involves 20. K-means would either fragment the large cluster or absorb the small one. HDBSCAN handles both naturally.

It worked perfectly on test data. On real data at scale — 89K events in 2,316 dimensions — it produced garbage. Either one mega-cluster or all noise.

The problem is the **curse of dimensionality**. Imagine finding "dense neighborhoods" in a room. Easy — people naturally cluster near the door, the bar, the stage. Now imagine a 2,316-dimensional room. In that space, every point is approximately equidistant from every other point. The mathematical reason: as dimensions increase, the ratio of the nearest distance to the farthest distance converges to 1. Density-based methods that rely on distance discrimination simply stop working.

The insight came from the topic modeling community. **BERTopic** and **Top2Vec** — the dominant approaches for clustering text embeddings — both use the same pipeline: reduce dimensions first (PCA for linear noise removal, then UMAP for nonlinear manifold learning), then cluster the reduced vectors. The reasoning is sound: the 2,316 dimensions contain both signal and noise. PCA strips the noise; UMAP preserves the signal's structure while collapsing it to a dimension where density has meaning.

---

## UMAP: The Manifold Hypothesis

UMAP (Uniform Manifold Approximation and Projection) is built on a beautiful idea: **the manifold hypothesis.** Even though your vectors live in 2,316 dimensions, the *meaningful* structure — the patterns, the clusters, the relationships — lives on a much lower-dimensional surface embedded in that space. Think of a sheet of paper crumpled into a ball. The paper is 2D; the ball is 3D. UMAP finds the crumpled paper and flattens it back out — without tearing it.

More precisely: UMAP preserves **local neighborhoods.** Points that are close in the original space should remain close in the reduced space. Points that are far apart should remain far apart. Global structure (which clusters are near which other clusters) is also preserved — unlike t-SNE, which distorts inter-cluster distances, making UMAP much better suited as a pre-processing step for clustering.

Our pure-Swift UMAP implementation has three stages:

**Stage 1: Build a neighborhood graph.** For each of the 89K points, find its 15 nearest neighbors. This creates a sparse graph that captures the local structure of the data.

**Stage 2: Compute fuzzy membership strengths.** Not all neighbors are equally close. UMAP converts hard kNN relationships into soft membership weights using an exponential kernel with per-point bandwidth — the bandwidth is found via binary search such that each point "sees" a consistent number of effective neighbors. The directed memberships are then symmetrized into an undirected graph via fuzzy union.

**Stage 3: Optimize a low-dimensional layout.** Starting from random positions in 25 dimensions, stochastic gradient descent iteratively adjusts the embedding. Connected points are pulled together (attractive forces); random non-neighbors are pushed apart (repulsive forces via negative sampling). After 200 epochs, the 25D layout preserves the local structure of the original 50D PCA-reduced space.

---

## The Performance Journey

Implementing the algorithms was the easy part. Making them run at the scale of 89K events was the engineering challenge. Each bottleneck we hit led to a deeper understanding of both the algorithms and the hardware.

**PCA: 2,316D to 50D in 3.6 seconds.** The covariance matrix computation was the first optimization target. The naive approach — transpose the N x D data matrix, then multiply — requires allocating an N x D intermediate array (89K x 2316 x 4 bytes = 790 MB). We replaced this with BLAS `cblas_ssyrk`, the symmetric rank-k update, which computes X^T X directly from the row-major data. No intermediate allocation. The eigendecomposition via LAPACK `ssyev_` then operates on the D x D covariance matrix (2316 x 2316 = 21 MB), which is N-independent.

**UMAP kNN: The VP-tree lie.** Vantage-Point trees are the textbook answer for k-nearest-neighbor search — O(N log N) construction, O(log N) queries. In practice, at 50 dimensions, VP-trees prune poorly. Most branches get visited because all distances converge. Our parallel VP-tree implementation (queries distributed across all CPU cores) still took 15 minutes for 89K vectors.

The fix: brute-force matrix multiply via `vDSP_mmul`. For normalized vectors, cosine similarity equals the dot product. We compute the full N x N similarity matrix in tiles (1.5 GB per tile), then extract top-k per row using a parallel fixed-size insertion sort. The key: `vDSP_mmul` routes to Apple Silicon's **AMX coprocessor** — a dedicated matrix multiply unit that operates at hardware speed. An 89K x 50 matrix multiply completes in ~100 milliseconds. Total: 75 seconds, down from 15 minutes.

**UMAP SGD: 1.4 billion `pow` calls.** The SGD inner loop computes `pow(distSq, b)` for every edge at every epoch — with 1M edges and 200 epochs, that's 1.4 billion calls to `powf()`, each taking ~20 nanoseconds. We replaced all per-dimension scalar loops with Accelerate `vDSP` vector operations (`vDSP_vsub` for diff, `vDSP_dotpr` for distance, `vDSP_vsmul` for scaling, `vDSP_vclip` for gradient clamping, `vDSP_vsma` for in-place updates) and replaced `powf(x, b)` with `expf(b * logf(x))` — single-precision transcendentals are 3x faster because the CPU has dedicated pipelines. Total SGD: 144 seconds for 200 epochs, down from ~600.

**HDBSCAN: From 128 GB to 15 MB.** The original implementation computed a full N x N distance matrix. At N=89K: 89,355^2 x 4 bytes = 32 GB per intermediate array, with four arrays totaling 128 GB. It crashed the machine. The fix: reuse the kNN graph from UMAP. HDBSCAN needs core distances (the k-th nearest neighbor distance per point) and a minimum spanning tree. Both can be derived from the sparse kNN graph — 89K x 15 edges = ~1.3M entries = 15 MB. Same algorithm, same results, 8,500x less memory.

---

## The Hardware Story

Every optimization above maps to a specific feature of Apple Silicon:

| Pipeline Stage | Hardware Feature | Why It Wins |
|---------------|------------------|-------------|
| PCA (covariance matrix) | **AMX coprocessor** | `cblas_ssyrk` routes to AMX for hardware matrix multiply |
| UMAP kNN (similarity matrix) | **AMX coprocessor** | `vDSP_mmul` for tiled N x N dot products at hardware speed |
| UMAP SGD (gradient updates) | **NEON SIMD** | `vDSP_vsub`, `vDSP_vsma` operate on 128-bit vector lanes |
| Nomic embeddings | **Neural Engine / GPU** | MLTensor routes attention through dedicated ML accelerators |
| All stages | **Unified Memory** | CPU, GPU, and Neural Engine share the same physical RAM — zero-copy |

The insight that runs through every optimization: **on Apple Silicon, algorithms that express work as matrix operations beat algorithms with better asymptotic complexity but branch-heavy execution.** VP-trees are O(N log N); brute-force matrix multiply is O(N^2 D). But the AMX coprocessor executes matrix multiply at a rate that makes the constant factor irrelevant at realistic data sizes.

---

## The Full Pipeline

Here's what happens when a user clicks "Recompute Themes" with 89K events on an M5 MacBook Pro:

| Stage | Time | Memory |
|-------|------|--------|
| IDF weights + event vectors | ~30s | ~200 MB |
| PCA: 2,316D to 50D | 3.6s | ~800 MB peak (N x D flat array + D x D covariance) |
| UMAP kNN: 50D, k=15 | 75s | ~1.5 GB per similarity tile |
| UMAP SGD: 200 epochs | 144s | ~9 MB (flat embedding buffer) |
| HDBSCAN (sparse) | ~30s | ~15 MB |
| Cluster artifacts + LLM labeling | ~60s | Minimal |
| **Total** | **~6 minutes** | **~2 GB peak** |

Every stage can be skipped or reconfigured independently via the Settings UI.

---

## Lessons Learned

**1. Automated knowledge graphs lower the cost of strategic awareness.** The value isn't the technology — it's replacing a human editorial process (people reading and synthesizing) with a computational one. The system reads 500 feeds so the innovation team doesn't have to.

**2. Know your hardware before choosing your algorithm.** VP-trees are theoretically optimal for kNN. On Apple Silicon with AMX, brute-force matrix multiply is faster. The best algorithm depends on what silicon you have.

**3. Dimensionality reduction is not optional for embedding clustering.** HDBSCAN on raw 2,316-dim vectors produced garbage. After PCA + UMAP to 25 dimensions, the same algorithm found clean, interpretable clusters. The BERTopic pipeline (PCA, UMAP, HDBSCAN) is the right default for any embedding-based clustering task.

**4. Actor isolation beats locks for GPU resource management.** Swift actors with continuation-based queues serialize GPU access cleanly. No locks, no deadlocks, no race conditions. Recover throughput by batching at the GPU level, not the concurrency level.

**5. Sparse representations save orders of magnitude in memory.** The HDBSCAN distance matrix needed 128 GB. The sparse kNN graph needed 15 MB. Same results. When you see an O(N^2) data structure, ask whether the algorithm actually *uses* all N^2 entries.

**6. Start with the naive implementation, measure, then optimize.** Every optimization in this project started with a correct-but-slow implementation and a profiler trace. We never optimized something that wasn't measured first.

**7. Local-first is a feature, not a compromise.** On-device embeddings, on-device clustering, on-device graph traversal. No API keys required for core functionality. The privacy and reliability wins are real, and users notice.

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
