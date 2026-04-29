import Foundation
import GRDB
import HyperGraphReasoning
import MCP

/// Full RAG query pipeline over the knowledge hypergraph.
///
/// Uses the app's existing services directly:
/// - `NomicEmbeddingService.shared` for on-device embeddings
/// - `HypergraphPathService` for BFS path finding
/// - `Database.current` for all queries
/// - `ContextCollector.extractRelation(from:)` for edge label extraction
///
/// Returns assembled context for the MCP client to synthesize — does NOT generate an LLM answer.
enum MCPQueryKnowledgeGraphTool {

    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.current) async throws -> String {
        guard let question = arguments["question"]?.stringValue, !question.isEmpty else {
            throw MCPToolError.missingParameter("question")
        }
        let maxNodes = arguments["max_nodes"]?.intValue ?? 5
        let maxChunks = arguments["max_chunks"]?.intValue ?? 5
        let maxPathDepth = arguments["max_path_depth"]?.intValue ?? 4

        // Step 1: Extract keywords using the configured LLM provider
        let keywords = await KeywordExtractionService.extractKeywords(from: question, database: database)
        guard !keywords.isEmpty else {
            return "Could not extract meaningful keywords from the question."
        }

        // Step 2: Embed each keyword with the app's NomicEmbeddingService and find similar nodes
        var allNodes: [NodeResult] = []
        var seenNodeIds: Set<Int64> = []

        for keyword in keywords {
            let embedding = try await NomicEmbeddingService.shared.embed(keyword)
            let embeddingData = embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            let nodes = try findSimilarNodes(queryEmbedding: embeddingData, limit: maxNodes, database: database)
            for node in nodes where !seenNodeIds.contains(node.id) {
                seenNodeIds.insert(node.id)
                allNodes.append(node)
            }
        }

        let similarNodes = allNodes.sorted { $0.distance < $1.distance }
        guard !similarNodes.isEmpty else {
            return "No similar concepts found in the knowledge graph for keywords: \(keywords.joined(separator: ", "))."
        }

        // Step 3: Embed full question for chunk similarity search
        let questionEmbedding = try await NomicEmbeddingService.shared.embed(question)
        let questionEmbeddingData = questionEmbedding.withUnsafeBufferPointer { Data(buffer: $0) }

        // Step 4: BFS reasoning paths using the app's HypergraphPathService
        let nodeIds = similarNodes.map { $0.id }
        let pathService = HypergraphPathService()
        let pathReports = try pathService.findPaths(
            between: nodeIds,
            intersectionThreshold: 1,
            maxPaths: 3,
            maxDepth: maxPathDepth
        )

        // Step 5: Gather edges for the nodes
        let edges = try findEdgesForNodes(nodeIds: nodeIds, database: database)

        // Step 6: Find similar chunks (with provenance fallback)
        var chunks = try findSimilarChunks(queryEmbedding: questionEmbeddingData, limit: maxChunks, database: database)
        if chunks.isEmpty {
            chunks = try findChunksFromProvenance(nodeIds: nodeIds, limit: maxChunks, database: database)
        }

        // Step 7: Find source articles
        let articles = try findSourceArticles(nodeIds: nodeIds, database: database)

        // Format reasoning paths
        let reasoningPaths = try formatReasoningPaths(pathReports, database: database)

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


    // MARK: - Vector Search

    private static let similarityThreshold: Double = 0.5

    private static func findSimilarNodes(queryEmbedding: Data, limit: Int, database: any MCPDatabaseReader) throws -> [NodeResult] {
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
                NodeResult(id: row["id"], label: row["label"], nodeType: row["node_type"], distance: row["distance"])
            }
        }
    }

    private static func findSimilarChunks(queryEmbedding: Data, limit: Int, database: any MCPDatabaseReader) throws -> [ChunkResult] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT ac.content, fi.title as article_title,
                       vec_distance_cosine(ce.embedding, ?) as distance
                FROM article_chunk ac
                JOIN chunk_embedding ce ON ac.id = ce.chunk_id
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                WHERE vec_distance_cosine(ce.embedding, ?) < ?
                ORDER BY distance ASC
                LIMIT ?
            """, arguments: [queryEmbedding, queryEmbedding, similarityThreshold, limit])

            return rows.map { row in
                ChunkResult(content: row["content"], articleTitle: row["article_title"], distance: row["distance"])
            }
        }
    }

    private static func findChunksFromProvenance(nodeIds: [Int64], limit: Int, database: any MCPDatabaseReader) throws -> [ChunkResult] {
        guard !nodeIds.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            var args = nodeIds.map { $0 as DatabaseValueConvertible }
            args.append(limit)
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT ac.content, fi.title as article_title, 0.0 as distance
                FROM hypergraph_incidence hi
                JOIN hypergraph_edge he ON hi.edge_id = he.id
                JOIN article_edge_provenance aep ON he.id = aep.edge_id
                JOIN article_chunk ac ON aep.feed_item_id = ac.feed_item_id
                    AND aep.chunk_index = ac.chunk_index
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                WHERE hi.node_id IN (\(placeholders))
                LIMIT ?
            """, arguments: StatementArguments(args))

            return rows.map { row in
                ChunkResult(content: row["content"], articleTitle: row["article_title"], distance: row["distance"])
            }
        }
    }

    // MARK: - Edge Gathering

    private static func findEdgesForNodes(nodeIds: [Int64], database: any MCPDatabaseReader) throws -> [EdgeResult] {
        guard !nodeIds.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
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
            """, arguments: StatementArguments(nodeIds))

            return rows.compactMap { row -> EdgeResult? in
                let sourcesStr: String? = row["sources"]
                let targetsStr: String? = row["targets"]
                let sources = sourcesStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []
                let targets = targetsStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []
                guard !sources.isEmpty || !targets.isEmpty else { return nil }

                let edgeIdStr: String = row["edge_id"]
                let label = ContextCollector.extractRelation(from: edgeIdStr) ?? row["label"] ?? "relates to"

                return EdgeResult(label: label, sourceNodes: sources, targetNodes: targets)
            }
        }
    }

    // MARK: - Source Articles

    private static func findSourceArticles(nodeIds: [Int64], database: any MCPDatabaseReader) throws -> [ArticleResult] {
        guard !nodeIds.isEmpty else { return [] }
        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT fi.title, fi.link, fi.pub_date, rs.title AS source_name
                FROM hypergraph_incidence hi
                JOIN hypergraph_edge he ON hi.edge_id = he.id
                JOIN article_edge_provenance aep ON he.id = aep.edge_id
                JOIN feed_item fi ON aep.feed_item_id = fi.id
                LEFT JOIN rss_source rs ON fi.source_id = rs.id
                WHERE hi.node_id IN (\(placeholders))
                LIMIT 10
            """, arguments: StatementArguments(nodeIds))

            return rows.map { row in
                ArticleResult(title: row["title"], link: row["link"], sourceName: row["source_name"], pubDate: row["pub_date"])
            }
        }
    }

    // MARK: - Reasoning Path Formatting

    private static func formatReasoningPaths(
        _ reports: [HypergraphPathService.PathReport],
        database: any MCPDatabaseReader
    ) throws -> [ReasoningPathResult] {
        var allEdgeIds: Set<Int64> = []
        for report in reports {
            for edgeId in report.edgePath { allEdgeIds.insert(edgeId) }
        }

        let edgeRelations: [Int64: String] = try database.read { db in
            guard !allEdgeIds.isEmpty else { return [:] }
            let placeholders = allEdgeIds.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, edge_id, label FROM hypergraph_edge WHERE id IN (\(placeholders))
            """, arguments: StatementArguments(Array(allEdgeIds)))

            var relations: [Int64: String] = [:]
            for row in rows {
                let id: Int64 = row["id"]
                let edgeIdStr: String = row["edge_id"]
                relations[id] = ContextCollector.extractRelation(from: edgeIdStr) ?? row["label"] ?? "relates to"
            }
            return relations
        }

        return reports.map { report in
            let intermediates = report.hops.flatMap { $0.intersectionNodes }
            let uniqueIntermediates = intermediates.reduce(into: [String]()) { result, node in
                if !result.contains(node) { result.append(node) }
            }
            let edgeLabels = report.edgePath.map { edgeRelations[$0] ?? "relates to" }

            return ReasoningPathResult(
                source: report.pair.0,
                target: report.pair.1,
                hops: report.edgePath.count,
                intermediates: uniqueIntermediates,
                edgeLabels: edgeLabels
            )
        }
    }

    // MARK: - Output Formatting

    private static func formatContext(
        question: String,
        keywords: [String],
        nodes: [NodeResult],
        reasoningPaths: [ReasoningPathResult],
        edges: [EdgeResult],
        chunks: [ChunkResult],
        articles: [ArticleResult]
    ) -> String {
        var output = "## Knowledge Graph Context for: \"\(question)\"\n\n"
        output += "**Keywords extracted:** \(keywords.joined(separator: ", "))\n\n"

        if !nodes.isEmpty {
            output += "### Related Concepts (\(nodes.count))\n"
            for node in nodes {
                let pct = Int(max(0, min(1, 1 - node.distance)) * 100)
                output += "- **\(node.label)**"
                if let type = node.nodeType { output += " (\(type))" }
                output += " — \(pct)% similar\n"
            }
            output += "\n"
        }

        if !reasoningPaths.isEmpty {
            output += "### Reasoning Paths\n"
            for path in reasoningPaths {
                output += "- **\(path.source)** → **\(path.target)** (\(path.hops) hop\(path.hops == 1 ? "" : "s"))"
                if !path.intermediates.isEmpty {
                    output += " via \(path.intermediates.joined(separator: ", "))"
                }
                output += "\n"
                for label in path.edgeLabels {
                    output += "  - \(label)\n"
                }
            }
            output += "\n"
        }

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

        if !chunks.isEmpty {
            output += "### Source Content (\(chunks.count) chunks)\n"
            for chunk in chunks {
                let pct = Int(max(0, min(1, 1 - chunk.distance)) * 100)
                output += "#### From: \(chunk.articleTitle)"
                if chunk.distance > 0 { output += " (\(pct)% relevant)" }
                output += "\n\(chunk.content)\n\n"
            }
        }

        if !articles.isEmpty {
            output += "### Source Articles (\(articles.count))\n"
            let dateFormatter = DateFormatter()
            dateFormatter.dateStyle = .medium
            for article in articles {
                output += "- **\(article.title)**"
                if let source = article.sourceName { output += " (\(source))" }
                if let pubDate = article.pubDate {
                    output += " — \(dateFormatter.string(from: Date(timeIntervalSince1970: pubDate)))"
                }
                if let link = article.link { output += "\n  \(link)" }
                output += "\n"
            }
        }

        return output
    }

    // MARK: - Result Types

    private struct NodeResult {
        let id: Int64
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
        let intermediates: [String]
        let edgeLabels: [String]
    }
}
