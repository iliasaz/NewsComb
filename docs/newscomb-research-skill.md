---
name: newscomb-research
description: Use the NewsComb MCP knowledge graph for news intelligence research -- entity discovery, relationship exploration, multi-hop reasoning paths, theme clustering, and evidence-backed analysis with source citations. Trigger when the user asks to research news topics, analyze entities, find connections between concepts, or produce intelligence reports.
argument-hint: "[research question or topic]"
---

# NewsComb News Intelligence Research

You are conducting research using the NewsComb knowledge hypergraph -- a structured graph built from RSS news feeds containing entities (nodes), relationships (hyperedges), article chunks, vector embeddings, and HDBSCAN story theme clusters.

Your goal: produce evidence-backed intelligence analysis with clear reasoning chains, provenance quotes, and source article citations.

## Available MCP Tools

| Tool | Purpose | When to use |
|------|---------|-------------|
| `query_knowledge_graph` | Full RAG pipeline: embed question, vector search, BFS reasoning paths, context assembly. Returns 5 sections: Related Concepts, Reasoning Paths, Relationships, Source Content (provenance chunks), and Source Articles (titles, dates, links) | Focused research questions -- the richest single-call tool, but can timeout on vague/broad queries |
| `search_concepts` | Full-text search for entity/concept nodes; returns type and event frequency | **Always start here** -- discover how entities are represented and their coverage |
| `get_node_neighbors` | All hyperedges connected to a node; returns relationship labels and provenance text | Core exploration tool -- reveals what the graph knows about an entity |
| `find_paths` | BFS multi-hop paths between two concepts (s-connectivity) | Structural analysis -- causal chains, influence paths, competitive distance |
| `search_chunks` | Full-text search over article text chunks; returns content with article title and link | Finding source articles, quotes, and evidence for specific claims |
| `get_themes` | HDBSCAN story theme clusters with labels, sizes, top entities, and summaries | Macro-level story landscape -- what clusters of events exist |
| `get_theme_details` | Detailed view of a single theme cluster | Deep-dive into a specific story cluster |
| `get_statistics` | Node/edge/article counts | Quick health check on graph coverage |
| `get_recent_articles` | Recently ingested articles | Checking freshness and recency of data |

## Research Workflow

Follow this phased approach. Each phase builds on the previous one. Maximize parallel tool calls within each phase.

### Phase 1: Entity Discovery

**Goal:** Understand how the target entities exist in the graph before exploring them.

Run `search_concepts` for each key entity in the research question. This tells you:
- The canonical node label (exact casing matters for later tools)
- The entity type (organization, person, non-actor, etc.)
- Event frequency (how much coverage exists -- low-frequency entities may need broader searches)
- Variant spellings (e.g., "Oracle Cloud Infrastructure" vs "Oracle Cloud Infrastructure (OCI)" are separate nodes)

**Pitfall:** If `search_concepts` returns nothing, the entity may not be in the graph. Try broader terms, abbreviations, or related concepts before concluding there's no coverage.

### Phase 2: Broad Parallel Exploration

**Goal:** Cast a wide net across multiple graph exploration methods simultaneously.

Run these in parallel (no dependencies between them):

1. **`get_node_neighbors`** for each primary entity (limit: 20-30). This is your most valuable tool -- it returns relationship labels AND provenance text (the original article snippet that created the relationship). Record:
   - Key relationships and their directionality
   - Provenance quotes worth citing
   - Connected entities that warrant further exploration

2. **`find_paths`** between the primary entities (max_depth: 4, max_paths: 5). The **hop count is analytically significant** -- it quantifies structural proximity. A 1-hop path means a direct documented relationship; a 4-hop path means the connection is indirect and mediated through intermediaries.

3. **`get_themes`** filtered by topic keywords. Theme clusters provide macro context -- they aggregate dozens of events into labeled story arcs with top entities and optional LLM summaries.

4. **`search_chunks`** with topic-specific keywords to find source articles with links. Use specific compound phrases rather than single words.

**Using `query_knowledge_graph` in Phase 2:** This tool runs the full RAG pipeline and returns the richest single-call output -- Related Concepts (with similarity scores), Reasoning Paths (BFS chains), Relationships (with provenance text), Source Content (article chunks with full text), and Source Articles (titles, dates, and links). It is extremely valuable when it works, but can timeout on broad/vague questions. Use it alongside the targeted tools, not instead of them. If it times out, you still have results from the parallel targeted calls. Keep the question focused and reduce `max_nodes` and `max_chunks` if needed.

### Phase 3: Targeted Evidence Gathering

**Goal:** Fill gaps and collect source citations for specific claims.

Based on Phase 2 findings, run targeted `search_chunks` queries to:
- Find the original article text behind key provenance snippets
- Collect article links for citation
- Verify claims before including them in the analysis

Also run:
- **`get_node_neighbors`** on newly discovered important entities from Phase 2
- **`get_theme_details`** on relevant theme cluster IDs
- **`find_paths`** between secondary entity pairs if new structural questions emerged

**Pitfall:** `search_chunks` uses FTS5 syntax. Avoid special characters that could break the SQL query. If a query errors, simplify it -- remove parentheses, quotes, and special punctuation. Use AND/OR/NOT operators and prefix* matching.

### Phase 4: Synthesis and Reporting

**Goal:** Produce the final analysis with full evidence trails.

Structure your output with:

1. **Claims backed by graph evidence** -- every major finding should reference:
   - The graph relationship or path that revealed it
   - A provenance quote (the extracted text from the source article)
   - The source article title and link

2. **Graph path diagrams** -- for multi-hop reasoning, show the BFS path as an ASCII diagram:
   ```
   Entity A --[relationship]--> Entity B --[relationship]--> Entity C
   ```

3. **Structural metrics** -- hop counts, event frequencies, theme cluster sizes. These quantify the strength of connections and coverage depth.

4. **Source article table** -- a reference table at the end listing all cited articles with their contribution to the analysis.

## Tool-Specific Tips

### search_concepts
- Use FTS5 syntax: `OpenClaw AND Oracle` or `prefix*`
- Check all returned variants -- "Oracle Cloud" and "Oracle Cloud Infrastructure (OCI)" are different nodes with different relationships
- Event frequency indicates coverage depth: 129 events = heavily covered; 1 event = barely mentioned

### get_node_neighbors
- Use the exact label from `search_concepts` results (case-insensitive but exact match)
- Set limit to 20-30 for primary entities; the provenance text is the most valuable output
- The relationship directionality matters: `A uses B` vs `B is used by A` tells different stories

### find_paths
- max_depth: 4 is usually sufficient; deeper paths are less meaningful
- The hop count difference between two entity pairs is itself an insight (e.g., OpenClaw-to-DigitalOcean: 1 hop vs OpenClaw-to-OCI: 4 hops reveals a strategic gap)
- Multiple paths between the same pair reveal different connection channels

### search_chunks
- Returns article title, link, and matching text -- this is your citation source
- Use compound phrases: `"OpenClaw supply chain attack"` works better than `"OpenClaw"`
- If you get an SQL error, simplify the query -- remove special characters and parentheses
- No results doesn't mean no coverage; try different keyword combinations

### get_themes
- Filter with the `query` parameter to narrow results
- Theme sizes indicate story significance: 131 events = major story arc; 10 events = minor thread
- Top entities in a theme reveal the key players in that story

### query_knowledge_graph
- Returns 5 structured sections:
  1. **Related Concepts** -- vector-similar nodes with similarity percentages and entity types
  2. **Reasoning Paths** -- BFS chains between discovered concepts (e.g., `NanoClaw -> OpenClaw (2 hops) via Cohen`)
  3. **Relationships** -- extracted hyperedge labels with provenance text (e.g., `OpenClaw **has** 43,000 deployments on DigitalOcean`)
  4. **Source Content** -- full-text article chunks with article titles (the richest provenance data)
  5. **Source Articles** -- titles, dates, and links for all articles that contributed to the response
- Best for focused, specific questions -- avoid vague multi-topic queries
- Reduce `max_nodes` (default 5) and `max_chunks` (default 5) if you hit timeouts; try `max_nodes: 3, max_chunks: 3` as a starting point
- The Source Articles section provides ready-made citations with links -- use these directly in your output
- Can timeout on broad questions -- always run it in parallel with targeted tools so you have fallback data

## Output Quality Checklist

Before delivering your analysis, verify:

- [ ] Every factual claim has a provenance quote or graph relationship backing it
- [ ] Source articles are cited with titles and links
- [ ] Graph paths are shown for structural/causal arguments
- [ ] Hop counts and event frequencies are used to quantify connection strength
- [ ] The methodology section documents which tools were used and what they found
- [ ] Findings are organized by theme (benefits/risks, opportunities/threats, etc.) not by tool
