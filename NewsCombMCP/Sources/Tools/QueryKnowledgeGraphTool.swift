import Foundation
import GRDB
import MCP

/// Full RAG query pipeline over the knowledge hypergraph.
///
/// Follows the app's GraphRAGService logic:
/// 1. Extract keywords from the question (stopword-based fallback)
/// 2. Embed each keyword with Nomic on-device embeddings
/// 3. Vector search on node_embedding (sqlite-vec cosine distance)
/// 4. BFS path finding between discovered nodes
/// 5. Gather direct edges, provenance chunks, and source articles
/// 6. Return assembled context (does NOT generate an LLM answer — the MCP client IS the LLM)
enum QueryKnowledgeGraphTool {

    // MARK: - Public Entry Point

    static func run(arguments: [String: Value], database: ReadOnlyDatabase) async throws -> String {
        guard let question = arguments["question"]?.stringValue, !question.isEmpty else {
            throw ToolError.missingParameter("question")
        }
        let maxNodes = arguments["max_nodes"]?.intValue ?? 5
        let maxChunks = arguments["max_chunks"]?.intValue ?? 5
        let maxPathDepth = arguments["max_path_depth"]?.intValue ?? 4

        // Step 1: Extract keywords
        let keywords = extractKeywords(from: question)
        guard !keywords.isEmpty else {
            return "Could not extract meaningful keywords from the question."
        }

        // Step 2: Embed each keyword and find similar nodes via vector search
        var allNodes: [SimilarNode] = []
        var seenNodeIds: Set<Int64> = []

        for keyword in keywords {
            let embedding = try await NomicEmbeddingService.shared.embed(keyword)
            let embeddingData = NomicEmbeddingService.embeddingToData(embedding)
            let nodes = try findSimilarNodes(
                queryEmbedding: embeddingData,
                limit: maxNodes,
                database: database
            )
            for node in nodes where !seenNodeIds.contains(node.id) {
                seenNodeIds.insert(node.id)
                allNodes.append(node)
            }
        }

        let similarNodes = allNodes.sorted { $0.distance < $1.distance }

        guard !similarNodes.isEmpty else {
            return "No similar concepts found in the knowledge graph for keywords: \(keywords.joined(separator: ", ")). The graph may not contain information about this topic."
        }

        // Step 3: Embed full question for chunk similarity search
        let questionEmbedding = try await NomicEmbeddingService.shared.embed(question)
        let questionEmbeddingData = NomicEmbeddingService.embeddingToData(questionEmbedding)

        // Step 4: BFS path finding between discovered nodes
        let nodeIds = similarNodes.map { $0.id }
        let reasoningPaths = try findReasoningPaths(
            nodeIds: nodeIds,
            maxDepth: maxPathDepth,
            database: database
        )

        // Step 5: Gather direct edges for the nodes
        let edges = try findEdgesForNodes(nodeIds: nodeIds, database: database)

        // Step 6: Find similar chunks via vector search (with provenance fallback)
        var chunks = try findSimilarChunks(
            queryEmbedding: questionEmbeddingData,
            limit: maxChunks,
            database: database
        )
        if chunks.isEmpty {
            chunks = try findChunksFromProvenance(
                nodeIds: nodeIds,
                limit: maxChunks,
                database: database
            )
        }

        // Step 7: Find source articles from edge provenance
        let articles = try findSourceArticles(nodeIds: nodeIds, database: database)

        // Format the assembled context
        return formatContext(
            question: question,
            keywords: keywords,
            nodes: similarNodes,
            reasoningPaths: reasoningPaths,
            edges: edges,
            chunks: chunks,
            articles: articles
        )
    }

    // MARK: - Keyword Extraction (Stopword-based fallback)

    /// Extracts keywords using stopword filtering.
    /// The MCP client (which IS the LLM) can do smarter extraction;
    /// this is a reasonable local fallback.
    private static func extractKeywords(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "must", "shall", "can", "need", "dare",
            "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
            "into", "through", "during", "before", "after", "above", "below",
            "between", "under", "again", "further", "then", "once", "here",
            "there", "when", "where", "why", "how", "all", "each", "few",
            "more", "most", "other", "some", "such", "no", "nor", "not",
            "only", "own", "same", "so", "than", "too", "very", "just",
            "and", "but", "if", "or", "because", "until", "while", "what",
            "which", "who", "whom", "this", "that", "these", "those", "am",
            "about", "it", "its", "they", "their", "them", "we", "us", "our",
            "you", "your", "he", "she", "him", "her", "his", "i", "me", "my",
            "tell", "explain", "describe", "show", "find", "get", "give",
            "know", "think", "say", "make", "go", "take", "come", "see",
            "look", "want", "use", "work", "call", "try", "ask", "let",
            "help", "talk", "turn", "start", "run", "move", "play",
            "related", "relationship", "between", "connect", "connection",
        ]

        let words = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }

        // Return unique keywords, max 5
        var seen: Set<String> = []
        var unique: [String] = []
        for word in words {
            if seen.insert(word).inserted {
                unique.append(word)
            }
            if unique.count >= 5 { break }
        }
        return unique
    }

    // MARK: - Vector Similarity Search

    /// Cosine distance threshold (0.5 ≈ 75% similarity).
    private static let similarityThreshold: Double = 0.5

    private static func findSimilarNodes(
        queryEmbedding: Data,
        limit: Int,
        database: ReadOnlyDatabase
    ) throws -> [SimilarNode] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT hn.id, hn.node_id, hn.label, hn.node_type,
                       vec_distance_cosine(ne.embedding, ?) as distance
                FROM hypergraph_node hn
                JOIN node_embedding ne ON hn.id = ne.node_id
                WHERE vec_distance_cosine(ne.embedding, ?) < ?
                ORDER BY distance ASC
                LIMIT ?
            """, arguments: [queryEmbedding, queryEmbedding, similarityThreshold, limit])

            return rows.map { row in
                SimilarNode(
                    id: row["id"],
                    nodeId: row["node_id"],
                    label: row["label"],
                    nodeType: row["node_type"],
                    distance: row["distance"]
                )
            }
        }
    }

    private static func findSimilarChunks(
        queryEmbedding: Data,
        limit: Int,
        database: ReadOnlyDatabase
    ) throws -> [ChunkResult] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ac.id as chunk_id, ac.chunk_index, ac.content,
                       vec_distance_cosine(ce.embedding, ?) as distance,
                       fi.id as article_id, fi.title as article_title
                FROM article_chunk ac
                JOIN chunk_embedding ce ON ac.id = ce.chunk_id
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                WHERE vec_distance_cosine(ce.embedding, ?) < ?
                ORDER BY distance ASC
                LIMIT ?
            """, arguments: [queryEmbedding, queryEmbedding, similarityThreshold, limit])

            return rows.map { row in
                ChunkResult(
                    content: row["content"],
                    articleTitle: row["article_title"],
                    distance: row["distance"]
                )
            }
        }
    }

    private static func findChunksFromProvenance(
        nodeIds: [Int64],
        limit: Int,
        database: ReadOnlyDatabase
    ) throws -> [ChunkResult] {
        guard !nodeIds.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT DISTINCT ac.content, fi.title as article_title, 0.0 as distance
                FROM hypergraph_incidence hi
                JOIN hypergraph_edge he ON hi.edge_id = he.id
                JOIN article_edge_provenance aep ON he.id = aep.edge_id
                JOIN article_chunk ac ON aep.feed_item_id = ac.feed_item_id
                    AND aep.chunk_index = ac.chunk_index
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                WHERE hi.node_id IN (\(placeholders))
                LIMIT ?
            """

            var args = nodeIds.map { $0 as DatabaseValueConvertible }
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                ChunkResult(
                    content: row["content"],
                    articleTitle: row["article_title"],
                    distance: row["distance"]
                )
            }
        }
    }

    // MARK: - BFS Reasoning Path Finding

    /// Finds reasoning paths between pairs of discovered nodes using BFS over hyperedge adjacency.
    private static func findReasoningPaths(
        nodeIds: [Int64],
        maxDepth: Int,
        database: ReadOnlyDatabase
    ) throws -> [ReasoningPathResult] {
        guard nodeIds.count >= 2 else { return [] }

        return try database.read { db in
            // Build hypergraph index
            var nodeToEdges: [Int64: Set<Int64>] = [:]
            var edgeToNodes: [Int64: Set<Int64>] = [:]
            var nodeLabels: [Int64: String] = [:]
            var edgeLabels: [Int64: String] = [:]
            var edgeIds: [Int64: String] = [:] // edge_id string for relation extraction

            let incidenceRows = try Row.fetchAll(db, sql: """
                SELECT hi.edge_id, hi.node_id, hn.label AS node_label,
                       he.label AS edge_label, he.edge_id AS edge_id_str
                FROM hypergraph_incidence hi
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                JOIN hypergraph_edge he ON hi.edge_id = he.id
            """)

            for row in incidenceRows {
                let edgeId: Int64 = row["edge_id"]
                let nodeId: Int64 = row["node_id"]
                nodeToEdges[nodeId, default: []].insert(edgeId)
                edgeToNodes[edgeId, default: []].insert(nodeId)
                nodeLabels[nodeId] = row["node_label"]
                edgeLabels[edgeId] = row["edge_label"]
                edgeIds[edgeId] = row["edge_id_str"]
            }

            // Precompute edge adjacency
            var edgeAdjacency: [Int64: Set<Int64>] = [:]
            for (edgeId, nodes) in edgeToNodes {
                var adjacent: Set<Int64> = []
                for nodeId in nodes {
                    if let candidateEdges = nodeToEdges[nodeId] {
                        for candidate in candidateEdges where candidate != edgeId {
                            adjacent.insert(candidate)
                        }
                    }
                }
                edgeAdjacency[edgeId] = adjacent
            }

            // BFS between pairs (limit to first 3 pairs to avoid explosion)
            var results: [ReasoningPathResult] = []
            let pairs = generatePairs(from: nodeIds, maxPairs: 3)

            for (sourceId, targetId) in pairs {
                let sourceEdges = nodeToEdges[sourceId] ?? []
                let targetEdges = nodeToEdges[targetId] ?? []
                guard !sourceEdges.isEmpty, !targetEdges.isEmpty else { continue }

                let sourceName = nodeLabels[sourceId] ?? "?"
                let targetName = nodeLabels[targetId] ?? "?"

                // BFS
                var queue: [(edge: Int64, depth: Int)] = []
                var visited: [Int64: Int] = [:]
                var parents: [Int64: [Int64]] = [:]

                for edge in sourceEdges {
                    queue.append((edge, 0))
                    visited[edge] = 0
                }

                var queueIndex = 0
                var found = false

                while queueIndex < queue.count {
                    let (currentEdge, currentDepth) = queue[queueIndex]
                    queueIndex += 1
                    if currentDepth > maxDepth { break }

                    if targetEdges.contains(currentEdge) {
                        // Reconstruct path
                        let edgePaths = reconstructPaths(to: currentEdge, parents: parents)
                        if let edgePath = edgePaths.first {
                            // Build readable path with edge labels
                            var steps: [String] = []
                            for (i, eid) in edgePath.enumerated() {
                                let relation = extractRelation(from: edgeIds[eid]) ?? edgeLabels[eid] ?? "relates to"
                                let nodes = edgeToNodes[eid] ?? []
                                let nodeNames = nodes.compactMap { nodeLabels[$0] }.sorted()

                                steps.append("\(relation) [\(nodeNames.joined(separator: ", "))]")

                                // Show connecting node
                                if i < edgePath.count - 1 {
                                    let nextNodes = edgeToNodes[edgePath[i + 1]] ?? []
                                    let shared = nodes.intersection(nextNodes)
                                    let sharedNames = shared.compactMap { nodeLabels[$0] }
                                    if let via = sharedNames.first {
                                        steps.append("via \(via)")
                                    }
                                }
                            }

                            results.append(ReasoningPathResult(
                                source: sourceName,
                                target: targetName,
                                hops: edgePath.count,
                                steps: steps
                            ))
                        }
                        found = true
                        break
                    }

                    let neighbors = edgeAdjacency[currentEdge] ?? []
                    let neighborDepth = currentDepth + 1
                    for neighbor in neighbors {
                        if visited[neighbor] == nil {
                            visited[neighbor] = neighborDepth
                            parents[neighbor, default: []].append(currentEdge)
                            queue.append((neighbor, neighborDepth))
                        } else if visited[neighbor] == neighborDepth {
                            parents[neighbor, default: []].append(currentEdge)
                        }
                    }
                }

                if !found {
                    results.append(ReasoningPathResult(
                        source: sourceName,
                        target: targetName,
                        hops: 0,
                        steps: ["No path found within \(maxDepth) hops"]
                    ))
                }
            }

            return results
        }
    }

    /// Generates pairs of node IDs for path finding.
    private static func generatePairs(from nodeIds: [Int64], maxPairs: Int) -> [(Int64, Int64)] {
        var pairs: [(Int64, Int64)] = []
        for i in 0..<nodeIds.count {
            for j in (i + 1)..<nodeIds.count {
                pairs.append((nodeIds[i], nodeIds[j]))
                if pairs.count >= maxPairs { return pairs }
            }
        }
        return pairs
    }

    /// Reconstructs paths from BFS parent pointers.
    private static func reconstructPaths(to edge: Int64, parents: [Int64: [Int64]]) -> [[Int64]] {
        guard let edgeParents = parents[edge], !edgeParents.isEmpty else {
            return [[edge]]
        }
        var allPaths: [[Int64]] = []
        for parent in edgeParents.prefix(1) { // Take first parent only
            let parentPaths = reconstructPaths(to: parent, parents: parents)
            for var path in parentPaths {
                path.append(edge)
                allPaths.append(path)
            }
        }
        return allPaths
    }

    // MARK: - Edge Gathering

    private static func findEdgesForNodes(
        nodeIds: [Int64],
        database: ReadOnlyDatabase
    ) throws -> [EdgeResult] {
        guard !nodeIds.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT he.id, he.edge_id, he.label, aep.chunk_text,
                       GROUP_CONCAT(DISTINCT CASE WHEN hi.role = 'source' THEN hn.label END) as sources,
                       GROUP_CONCAT(DISTINCT CASE WHEN hi.role = 'target' THEN hn.label END) as targets
                FROM hypergraph_edge he
                JOIN hypergraph_incidence hi ON he.id = hi.edge_id
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                LEFT JOIN article_edge_provenance aep ON he.id = aep.edge_id
                WHERE he.id IN (
                    SELECT DISTINCT edge_id FROM hypergraph_incidence WHERE node_id IN (\(placeholders))
                )
                GROUP BY he.id
                LIMIT 30
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(nodeIds))
            return rows.compactMap { row -> EdgeResult? in
                let sourcesStr: String? = row["sources"]
                let targetsStr: String? = row["targets"]
                let sources = sourcesStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []
                let targets = targetsStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []
                guard !sources.isEmpty || !targets.isEmpty else { return nil }

                let edgeIdStr: String = row["edge_id"]
                let label = extractRelation(from: edgeIdStr) ?? row["label"] ?? "relates to"

                return EdgeResult(
                    label: label,
                    sourceNodes: sources,
                    targetNodes: targets,
                    provenanceText: row["chunk_text"]
                )
            }
        }
    }

    // MARK: - Source Articles

    private static func findSourceArticles(
        nodeIds: [Int64],
        database: ReadOnlyDatabase
    ) throws -> [ArticleResult] {
        guard !nodeIds.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT DISTINCT fi.title, fi.link, fi.pub_date, rs.title AS source_name
                FROM hypergraph_incidence hi
                JOIN hypergraph_edge he ON hi.edge_id = he.id
                JOIN article_edge_provenance aep ON he.id = aep.edge_id
                JOIN feed_item fi ON aep.feed_item_id = fi.id
                LEFT JOIN rss_source rs ON fi.source_id = rs.id
                WHERE hi.node_id IN (\(placeholders))
                LIMIT 10
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(nodeIds))
            return rows.map { row in
                ArticleResult(
                    title: row["title"],
                    link: row["link"],
                    sourceName: row["source_name"],
                    pubDate: row["pub_date"]
                )
            }
        }
    }

    // MARK: - Relation Extraction

    /// Extracts a human-readable relation from an edge_id string.
    /// Edge ID format: "relation_chunkXXX_N" → extracts "relation" part,
    /// replacing underscores with spaces.
    private static func extractRelation(from edgeId: String?) -> String? {
        guard let edgeId, !edgeId.isEmpty else { return nil }

        // Split at "_chunk" and take the prefix
        guard let range = edgeId.range(of: "_chunk") else { return nil }
        let prefix = String(edgeId[edgeId.startIndex..<range.lowerBound])
        guard !prefix.isEmpty else { return nil }

        return prefix.replacing("_", with: " ")
    }

    // MARK: - Output Formatting

    private static func formatContext(
        question: String,
        keywords: [String],
        nodes: [SimilarNode],
        reasoningPaths: [ReasoningPathResult],
        edges: [EdgeResult],
        chunks: [ChunkResult],
        articles: [ArticleResult]
    ) -> String {
        var output = "## Knowledge Graph Context for: \"\(question)\"\n\n"
        output += "**Keywords extracted:** \(keywords.joined(separator: ", "))\n\n"

        // Related concepts
        if !nodes.isEmpty {
            output += "### Related Concepts (\(nodes.count))\n"
            for node in nodes {
                let similarity = max(0, min(1, 1 - node.distance))
                let pct = Int(similarity * 100)
                output += "- **\(node.label)**"
                if let type = node.nodeType {
                    output += " (\(type))"
                }
                output += " — \(pct)% similar\n"
            }
            output += "\n"
        }

        // Reasoning paths
        if !reasoningPaths.isEmpty {
            output += "### Reasoning Paths\n"
            for path in reasoningPaths {
                if path.hops == 0 {
                    output += "- **\(path.source)** ↔ **\(path.target)**: \(path.steps.first ?? "no connection")\n"
                } else {
                    output += "- **\(path.source)** → **\(path.target)** (\(path.hops) hop\(path.hops == 1 ? "" : "s")):\n"
                    for step in path.steps {
                        output += "  - \(step)\n"
                    }
                }
            }
            output += "\n"
        }

        // Relationships
        if !edges.isEmpty {
            output += "### Relationships (\(edges.count))\n"
            for edge in edges.prefix(20) {
                let sources = edge.sourceNodes.joined(separator: ", ")
                let targets = edge.targetNodes.joined(separator: ", ")
                if targets.isEmpty {
                    output += "- \(sources) **\(edge.label)**\n"
                } else {
                    output += "- \(sources) **\(edge.label)** \(targets)\n"
                }
            }
            output += "\n"
        }

        // Source content chunks
        if !chunks.isEmpty {
            output += "### Source Content (\(chunks.count) chunks)\n"
            for chunk in chunks {
                let similarity = max(0, min(1, 1 - chunk.distance))
                let pct = Int(similarity * 100)
                output += "#### From: \(chunk.articleTitle)"
                if chunk.distance > 0 {
                    output += " (\(pct)% relevant)"
                }
                output += "\n\(chunk.content)\n\n"
            }
        }

        // Source articles
        if !articles.isEmpty {
            output += "### Source Articles (\(articles.count))\n"
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium

            for article in articles {
                output += "- **\(article.title)**"
                if let source = article.sourceName {
                    output += " (\(source))"
                }
                if let pubDate = article.pubDate {
                    let date = Date(timeIntervalSince1970: pubDate)
                    output += " — \(dateFormatter.string(from: date))"
                }
                if let link = article.link {
                    output += "\n  \(link)"
                }
                output += "\n"
            }
        }

        return output
    }

    // MARK: - Result Types

    private struct SimilarNode {
        let id: Int64
        let nodeId: String
        let label: String
        let nodeType: String?
        let distance: Double
    }

    private struct ChunkResult {
        let content: String
        let articleTitle: String
        let distance: Double
    }

    private struct EdgeResult {
        let label: String
        let sourceNodes: [String]
        let targetNodes: [String]
        let provenanceText: String?
    }

    private struct ArticleResult {
        let title: String
        let link: String?
        let sourceName: String?
        let pubDate: Double?
    }

    private struct ReasoningPathResult {
        let source: String
        let target: String
        let hops: Int
        let steps: [String]
    }
}
