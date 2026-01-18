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
    let relation: String
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
                SELECT id, edge_id, relation
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
                let relation: String = row["relation"] ?? ""

                return GraphEdge(
                    id: id,
                    edgeId: edgeId,
                    relation: relation,
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
                SELECT id, edge_id, relation
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
                let relation: String = row["relation"] ?? ""

                return GraphEdge(
                    id: id,
                    edgeId: edgeId,
                    relation: relation,
                    sourceNodeIds: sourcesByEdge[id] ?? [],
                    targetNodeIds: targetsByEdge[id] ?? []
                )
            }
        }
    }
}
