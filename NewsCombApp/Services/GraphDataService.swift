import Foundation
import GRDB

/// Represents a node in the graph visualization.
struct GraphNode: Identifiable, Equatable {
    let id: Int64
    let label: String
    let nodeType: String?
    var position: CGPoint = .zero
    var degree: Int = 0
}

/// Represents an edge (hyperedge) in the graph visualization.
struct GraphEdge: Identifiable, Equatable {
    let id: Int64
    let edgeId: String
    let label: String
    let sourceNodeIds: [Int64]
    let targetNodeIds: [Int64]
}

/// Container for graph data.
struct GraphData {
    var nodes: [GraphNode]
    var edges: [GraphEdge]
    var maxDegree: Int = 0
}

/// Service for loading graph data from the database.
final class GraphDataService: Sendable {

    private let database = Database.shared

    /// Load the complete hypergraph from the database.
    func loadFullGraph() throws -> GraphData {
        // Load all nodes
        let nodes = try loadAllNodes()

        // Load all edges with their incidences
        let edges = try loadAllEdges()

        // Calculate degrees
        var degreeMap: [Int64: Int] = [:]
        for edge in edges {
            for nodeId in edge.sourceNodeIds + edge.targetNodeIds {
                degreeMap[nodeId, default: 0] += 1
            }
        }

        // Apply degrees to nodes
        let nodesWithDegrees = nodes.map { node in
            var mutableNode = node
            mutableNode.degree = degreeMap[node.id] ?? 0
            return mutableNode
        }

        // Compute max degree
        let maxDegree = degreeMap.values.max() ?? 0

        return GraphData(nodes: nodesWithDegrees, edges: edges, maxDegree: maxDegree)
    }

    /// Load a subgraph containing only the specified nodes and their connected edges.
    func loadSubgraph(nodeIds: [Int64]) throws -> GraphData {
        guard !nodeIds.isEmpty else {
            return GraphData(nodes: [], edges: [])
        }

        // Load specified nodes
        let nodes = try loadNodes(ids: nodeIds)

        // Load edges connected to these nodes
        let edges = try loadEdgesForNodes(nodeIds: nodeIds)

        // Calculate degrees within subgraph
        var degreeMap: [Int64: Int] = [:]
        for edge in edges {
            for nodeId in edge.sourceNodeIds + edge.targetNodeIds {
                if nodeIds.contains(nodeId) {
                    degreeMap[nodeId, default: 0] += 1
                }
            }
        }

        let nodesWithDegrees = nodes.map { node in
            var mutableNode = node
            mutableNode.degree = degreeMap[node.id] ?? 0
            return mutableNode
        }

        // Compute max degree within subgraph
        let maxDegree = degreeMap.values.max() ?? 0

        return GraphData(nodes: nodesWithDegrees, edges: edges, maxDegree: maxDegree)
    }

    /// Load nodes connected to a given node (1-hop neighborhood).
    func loadNeighborhood(nodeId: Int64) throws -> GraphData {
        // Find all edges connected to this node
        let connectedEdgeIds = try database.read { db in
            try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT edge_id
                    FROM hypergraph_incidence
                    WHERE node_id = ?
                """,
                arguments: [nodeId]
            )
        }

        guard !connectedEdgeIds.isEmpty else {
            // No edges - just return the single node
            let singleNode = try loadNodes(ids: [nodeId])
            return GraphData(nodes: singleNode, edges: [])
        }

        // Find all nodes connected to these edges
        let neighborNodeIds = try database.read { db in
            let placeholders = connectedEdgeIds.map { _ in "?" }.joined(separator: ",")
            return try Int64.fetchAll(
                db,
                sql: """
                    SELECT DISTINCT node_id
                    FROM hypergraph_incidence
                    WHERE edge_id IN (\(placeholders))
                """,
                arguments: StatementArguments(connectedEdgeIds)
            )
        }

        return try loadSubgraph(nodeIds: neighborNodeIds)
    }

    /// Load direct neighbors of a node (nodes connected via shared edges).
    func loadNeighbors(nodeId: Int64) throws -> [GraphNode] {
        try database.read { db in
            let sql = """
                SELECT DISTINCT hn.id, hn.label, hn.node_type
                FROM hypergraph_node hn
                JOIN hypergraph_incidence hi1 ON hn.id = hi1.node_id
                JOIN hypergraph_incidence hi2 ON hi1.edge_id = hi2.edge_id
                WHERE hi2.node_id = ? AND hn.id != ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [nodeId, nodeId])
            return rows.compactMap { row -> GraphNode? in
                guard let id: Int64 = row["id"] else { return nil }
                let label: String = row["label"] ?? "Unknown"
                let nodeType: String? = row["node_type"]
                return GraphNode(id: id, label: label, nodeType: nodeType)
            }
        }
    }

    // MARK: - Provenance Loading

    /// Load provenance sources for a node by finding all edges it participates in
    /// and retrieving the article chunks that generated those edges.
    ///
    /// Uses UNION to independently query two provenance paths:
    /// 1. edge → article_edge_provenance → feed_item (explicit provenance records)
    /// 2. edge → article_chunk (via source_chunk_id) → feed_item (chunk-level link)
    ///
    /// When article_edge_provenance has a NULL chunk_text, we fall back to
    /// fetching the content from article_chunk using feed_item_id + chunk_index.
    func loadProvenanceForNode(nodeId: Int64) throws -> [ProvenanceSource] {
        try database.read { db in
            let sql = """
                SELECT feed_item_id, title, link, pub_date, chunk_text, chunk_index
                FROM (
                    -- Path 1: via article_edge_provenance
                    SELECT fi.id as feed_item_id, fi.title, fi.link, fi.pub_date,
                           COALESCE(aep.chunk_text, ac_fallback.content) as chunk_text,
                           COALESCE(aep.chunk_index, 0) as chunk_index
                    FROM hypergraph_incidence hi
                    JOIN hypergraph_edge he ON hi.edge_id = he.id
                    JOIN article_edge_provenance aep ON he.id = aep.edge_id
                    JOIN feed_item fi ON aep.feed_item_id = fi.id
                    LEFT JOIN article_chunk ac_fallback
                        ON ac_fallback.feed_item_id = aep.feed_item_id
                        AND ac_fallback.chunk_index = aep.chunk_index
                    WHERE hi.node_id = ?

                    UNION

                    -- Path 2: via source_chunk_id on the edge
                    SELECT fi.id as feed_item_id, fi.title, fi.link, fi.pub_date,
                           ac.content as chunk_text,
                           ac.chunk_index as chunk_index
                    FROM hypergraph_incidence hi
                    JOIN hypergraph_edge he ON hi.edge_id = he.id
                    JOIN article_chunk ac ON he.source_chunk_id = ac.id
                    JOIN feed_item fi ON ac.feed_item_id = fi.id
                    WHERE hi.node_id = ?
                )
                ORDER BY pub_date DESC
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [nodeId, nodeId])
            return parseProvenanceRows(rows)
        }
    }

    /// Load provenance sources for an edge directly.
    ///
    /// Uses UNION to independently query two provenance paths:
    /// 1. edge → article_edge_provenance → feed_item
    /// 2. edge → article_chunk (via source_chunk_id) → feed_item
    func loadProvenanceForEdge(edgeId: Int64) throws -> [ProvenanceSource] {
        try database.read { db in
            let sql = """
                SELECT feed_item_id, title, link, pub_date, chunk_text, chunk_index
                FROM (
                    -- Path 1: via article_edge_provenance
                    SELECT fi.id as feed_item_id, fi.title, fi.link, fi.pub_date,
                           COALESCE(aep.chunk_text, ac_fallback.content) as chunk_text,
                           COALESCE(aep.chunk_index, 0) as chunk_index
                    FROM hypergraph_edge he
                    JOIN article_edge_provenance aep ON he.id = aep.edge_id
                    JOIN feed_item fi ON aep.feed_item_id = fi.id
                    LEFT JOIN article_chunk ac_fallback
                        ON ac_fallback.feed_item_id = aep.feed_item_id
                        AND ac_fallback.chunk_index = aep.chunk_index
                    WHERE he.id = ?

                    UNION

                    -- Path 2: via source_chunk_id on the edge
                    SELECT fi.id as feed_item_id, fi.title, fi.link, fi.pub_date,
                           ac.content as chunk_text,
                           ac.chunk_index as chunk_index
                    FROM hypergraph_edge he
                    JOIN article_chunk ac ON he.source_chunk_id = ac.id
                    JOIN feed_item fi ON ac.feed_item_id = fi.id
                    WHERE he.id = ?
                )
                ORDER BY pub_date DESC
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [edgeId, edgeId])
            return parseProvenanceRows(rows)
        }
    }

    /// Parse provenance rows into ProvenanceSource objects.
    /// Allows NULL/empty chunk_text, providing a fallback message.
    private func parseProvenanceRows(_ rows: [Row]) -> [ProvenanceSource] {
        rows.compactMap { row -> ProvenanceSource? in
            guard let feedItemId: Int64 = row["feed_item_id"],
                  let title: String = row["title"] else {
                return nil
            }

            let chunkText: String = row["chunk_text"] ?? "(Source text not available)"

            return ProvenanceSource(
                feedItemId: feedItemId,
                title: title,
                link: row["link"],
                pubDate: row["pub_date"],
                chunkText: chunkText,
                chunkIndex: row["chunk_index"] ?? 0
            )
        }
    }

    /// Load the label for a node by its ID.
    func loadNodeLabel(nodeId: Int64) throws -> String? {
        try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT label FROM hypergraph_node WHERE id = ?",
                arguments: [nodeId]
            )
        }
    }

    /// Load the label for an edge by its ID.
    func loadEdgeLabel(edgeId: Int64) throws -> String? {
        try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT label FROM hypergraph_edge WHERE id = ?",
                arguments: [edgeId]
            )
        }
    }

    // MARK: - Full-Text Search

    /// Search node labels using FTS5 full-text search.
    func searchNodes(query: String, limit: Int = 50) throws -> [FTSNodeMatch] {
        let ftsQuery = Self.sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try database.read { db in
            let sql = """
                SELECT hn.id, hn.label, hn.node_type,
                       snippet(fts_node, 0, '<b>', '</b>', '...', 32) AS snippet,
                       bm25(fts_node) AS rank
                FROM fts_node
                JOIN hypergraph_node hn ON hn.id = fts_node.rowid
                WHERE fts_node MATCH ?
                ORDER BY rank
                LIMIT ?
            """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [ftsQuery, limit])
            return rows.compactMap { row -> FTSNodeMatch? in
                guard let id: Int64 = row["id"] else { return nil }
                return FTSNodeMatch(
                    id: id,
                    label: row["label"] ?? "",
                    nodeType: row["node_type"],
                    snippet: row["snippet"] ?? "",
                    rank: row["rank"] ?? 0
                )
            }
        }
    }

    /// Search article chunk content and resolve matching chunks to their derived nodes.
    ///
    /// Uses FTS5 to find chunks whose content matches the query, then resolves
    /// each chunk to the graph nodes it generated via two provenance paths:
    /// 1. `hypergraph_edge.source_chunk_id` (direct FK)
    /// 2. `article_edge_provenance` (feed_item_id + chunk_index match)
    func searchContentDerivedNodes(query: String, limit: Int = 30) throws -> [FTSNodeMatch] {
        let ftsQuery = Self.sanitizeFTSQuery(query)
        guard !ftsQuery.isEmpty else { return [] }

        return try database.read { db in
            // Step 1: Find matching chunks
            let chunkSQL = """
                SELECT ac.id AS chunk_id, ac.feed_item_id, ac.chunk_index,
                       fi.title AS article_title,
                       snippet(fts_chunk, 0, '<b>', '</b>', '...', 48) AS snippet,
                       bm25(fts_chunk) AS rank
                FROM fts_chunk
                JOIN article_chunk ac ON ac.id = fts_chunk.rowid
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                WHERE fts_chunk MATCH ?
                ORDER BY rank
                LIMIT ?
            """
            let chunkRows = try Row.fetchAll(db, sql: chunkSQL, arguments: [ftsQuery, limit])

            // Step 2: For each chunk, resolve associated node IDs via both provenance paths
            let nodeResolutionSQL = """
                SELECT DISTINCT hi.node_id FROM (
                    SELECT he.id AS edge_id
                    FROM hypergraph_edge he
                    WHERE he.source_chunk_id = ?

                    UNION

                    SELECT aep.edge_id
                    FROM article_edge_provenance aep
                    WHERE aep.feed_item_id = ? AND aep.chunk_index = ?
                ) matched_edges
                JOIN hypergraph_incidence hi ON matched_edges.edge_id = hi.edge_id
            """

            // Accumulate the best (rank, snippet, articleTitle) per node
            var nodeInfo: [Int64: (rank: Double, snippet: String, articleTitle: String)] = [:]

            for row in chunkRows {
                guard let chunkId: Int64 = row["chunk_id"],
                      let feedItemId: Int64 = row["feed_item_id"] else { continue }
                let chunkIndex: Int = row["chunk_index"] ?? 0
                let snippet: String = row["snippet"] ?? ""
                let articleTitle: String = row["article_title"] ?? ""
                let rank: Double = row["rank"] ?? 0

                let nodeIds = try Int64.fetchAll(
                    db, sql: nodeResolutionSQL,
                    arguments: [chunkId, feedItemId, chunkIndex]
                )

                for nodeId in nodeIds {
                    if let existing = nodeInfo[nodeId] {
                        // Keep the better-ranked match (lower bm25 = better)
                        if rank < existing.rank {
                            nodeInfo[nodeId] = (rank, snippet, articleTitle)
                        }
                    } else {
                        nodeInfo[nodeId] = (rank, snippet, articleTitle)
                    }
                }
            }

            guard !nodeInfo.isEmpty else { return [] }

            // Step 3: Load node details (label, type)
            let nodeIds = Array(nodeInfo.keys)
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ",")
            let nodeSQL = """
                SELECT id, label, node_type
                FROM hypergraph_node
                WHERE id IN (\(placeholders))
            """
            let nodeRows = try Row.fetchAll(db, sql: nodeSQL, arguments: StatementArguments(nodeIds))

            return nodeRows.compactMap { row -> FTSNodeMatch? in
                guard let id: Int64 = row["id"],
                      let info = nodeInfo[id] else { return nil }
                return FTSNodeMatch(
                    id: id,
                    label: row["label"] ?? "",
                    nodeType: row["node_type"],
                    snippet: info.snippet,
                    rank: info.rank,
                    articleTitle: info.articleTitle
                )
            }
            .sorted { $0.rank < $1.rank }
        }
    }

    /// Run both node-label and article-content searches, returning combined results.
    ///
    /// Nodes found via article content that already appear in direct label matches
    /// are deduplicated — the direct match takes precedence.
    func searchAll(query: String) throws -> GraphSearchResults {
        let nodeMatches = try searchNodes(query: query)
        let contentDerived = try searchContentDerivedNodes(query: query)

        // Deduplicate: exclude content-derived nodes that already matched by label
        let directIds = Set(nodeMatches.map(\.id))
        let uniqueContentDerived = contentDerived.filter { !directIds.contains($0.id) }

        return GraphSearchResults(
            query: query,
            nodeMatches: nodeMatches,
            contentDerivedNodes: uniqueContentDerived
        )
    }

    /// Sanitize user input for FTS5 MATCH syntax.
    ///
    /// Wraps each word in double quotes (escaping FTS5 special characters)
    /// and appends `*` to the last token for prefix matching.
    static func sanitizeFTSQuery(_ input: String) -> String {
        let words = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }

        guard !words.isEmpty else { return "" }

        var quoted = words.map { word in
            let escaped = word.replacing("\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        // Append prefix match to last token
        if var last = quoted.last {
            last = String(last.dropLast()) + "*\""
            quoted[quoted.count - 1] = last
        }

        return quoted.joined(separator: " ")
    }

    // MARK: - Private Methods

    private func loadAllNodes() throws -> [GraphNode] {
        try database.read { db in
            let sql = """
                SELECT id, label, node_type
                FROM hypergraph_node
                ORDER BY id
            """

            let rows = try Row.fetchAll(db, sql: sql)
            return rows.compactMap { row -> GraphNode? in
                guard let id: Int64 = row["id"] else { return nil }
                let label: String = row["label"] ?? "Unknown"
                let nodeType: String? = row["node_type"]
                return GraphNode(id: id, label: label, nodeType: nodeType)
            }
        }
    }

    private func loadNodes(ids: [Int64]) throws -> [GraphNode] {
        guard !ids.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT id, label, node_type
                FROM hypergraph_node
                WHERE id IN (\(placeholders))
                ORDER BY id
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(ids))
            return rows.compactMap { row -> GraphNode? in
                guard let id: Int64 = row["id"] else { return nil }
                let label: String = row["label"] ?? "Unknown"
                let nodeType: String? = row["node_type"]
                return GraphNode(id: id, label: label, nodeType: nodeType)
            }
        }
    }

    private func loadAllEdges() throws -> [GraphEdge] {
        try database.read { db in
            // Load all edges
            let edgeSQL = """
                SELECT id, edge_id, label
                FROM hypergraph_edge
                ORDER BY id
            """
            let edgeRows = try Row.fetchAll(db, sql: edgeSQL)

            // Load all incidences
            let incidenceSQL = """
                SELECT edge_id, node_id, role
                FROM hypergraph_incidence
                ORDER BY edge_id, position
            """
            let incidenceRows = try Row.fetchAll(db, sql: incidenceSQL)

            // Group incidences by edge_id
            var sourcesByEdge: [Int64: [Int64]] = [:]
            var targetsByEdge: [Int64: [Int64]] = [:]

            for row in incidenceRows {
                let edgeId: Int64 = row["edge_id"]
                let nodeId: Int64 = row["node_id"]
                let role: String = row["role"]

                if role == HypergraphIncidence.roleSource {
                    sourcesByEdge[edgeId, default: []].append(nodeId)
                } else if role == HypergraphIncidence.roleTarget {
                    targetsByEdge[edgeId, default: []].append(nodeId)
                }
            }

            // Build edges
            return edgeRows.compactMap { row -> GraphEdge? in
                guard let id: Int64 = row["id"] else { return nil }
                let edgeId: String = row["edge_id"] ?? ""
                let label: String = row["label"] ?? ""

                return GraphEdge(
                    id: id,
                    edgeId: edgeId,
                    label: label,
                    sourceNodeIds: sourcesByEdge[id] ?? [],
                    targetNodeIds: targetsByEdge[id] ?? []
                )
            }
        }
    }

    private func loadEdgesForNodes(nodeIds: [Int64]) throws -> [GraphEdge] {
        guard !nodeIds.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ",")

            // Find all edge IDs connected to these nodes
            let edgeIdsSQL = """
                SELECT DISTINCT edge_id
                FROM hypergraph_incidence
                WHERE node_id IN (\(placeholders))
            """
            let edgeDbIds = try Int64.fetchAll(db, sql: edgeIdsSQL, arguments: StatementArguments(nodeIds))

            guard !edgeDbIds.isEmpty else { return [] }

            // Load edge details
            let edgePlaceholders = edgeDbIds.map { _ in "?" }.joined(separator: ",")
            let edgeSQL = """
                SELECT id, edge_id, label
                FROM hypergraph_edge
                WHERE id IN (\(edgePlaceholders))
            """
            let edgeRows = try Row.fetchAll(db, sql: edgeSQL, arguments: StatementArguments(edgeDbIds))

            // Load incidences for these edges
            let incidenceSQL = """
                SELECT edge_id, node_id, role
                FROM hypergraph_incidence
                WHERE edge_id IN (\(edgePlaceholders))
                ORDER BY edge_id, position
            """
            let incidenceRows = try Row.fetchAll(db, sql: incidenceSQL, arguments: StatementArguments(edgeDbIds))

            // Group incidences by edge_id
            var sourcesByEdge: [Int64: [Int64]] = [:]
            var targetsByEdge: [Int64: [Int64]] = [:]

            for row in incidenceRows {
                let edgeId: Int64 = row["edge_id"]
                let nodeId: Int64 = row["node_id"]
                let role: String = row["role"]

                if role == HypergraphIncidence.roleSource {
                    sourcesByEdge[edgeId, default: []].append(nodeId)
                } else if role == HypergraphIncidence.roleTarget {
                    targetsByEdge[edgeId, default: []].append(nodeId)
                }
            }

            // Build edges
            return edgeRows.compactMap { row -> GraphEdge? in
                guard let id: Int64 = row["id"] else { return nil }
                let edgeId: String = row["edge_id"] ?? ""
                let label: String = row["label"] ?? ""

                return GraphEdge(
                    id: id,
                    edgeId: edgeId,
                    label: label,
                    sourceNodeIds: sourcesByEdge[id] ?? [],
                    targetNodeIds: targetsByEdge[id] ?? []
                )
            }
        }
    }
}
