import Foundation
import GRDB
import OSLog

/// Service for finding paths through the hypergraph using BFS.
/// Implements the path-finding algorithm from the Python GraphReasoning library.
final class HypergraphPathService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "HypergraphPathService")

    // MARK: - Types

    /// A path through the hypergraph consisting of connected edges.
    struct HypergraphPath: Sendable {
        let sourceNode: String
        let targetNode: String
        let edgePath: [Int64]
        let hops: [PathHop]
    }

    /// A single hop in a hypergraph path showing how two edges connect.
    struct PathHop: Sendable {
        let fromEdge: Int64
        let toEdge: Int64
        let intersectionNodes: [String]
    }

    /// Detailed report for a path between two nodes.
    struct PathReport: Sendable {
        let pair: (String, String)
        let edgePath: [Int64]
        let hops: [PathHop]
        let edgeMembers: [Int64: [String]]
    }

    // MARK: - Path Finding

    /// Finds shortest hypergraph paths between pairs of nodes.
    /// - Parameters:
    ///   - nodeIds: The node IDs to find paths between (finds paths between all pairs)
    ///   - intersectionThreshold: Minimum number of shared nodes for edges to be "connected" (s-connectivity)
    ///   - maxPaths: Maximum number of paths to find per node pair
    /// - Returns: Array of path reports
    func findPaths(
        between nodeIds: [Int64],
        intersectionThreshold: Int = 1,
        maxPaths: Int = 3
    ) throws -> [PathReport] {
        guard nodeIds.count >= 2 else { return [] }

        // Build the hypergraph index
        let index = try buildHypergraphIndex()
        logger.info("Built hypergraph index: \(index.nodeToEdges.count) nodes, \(index.edgeToNodes.count) edges")

        // Get node labels for reporting
        let nodeLabels = try fetchNodeLabels(for: nodeIds)

        var reports: [PathReport] = []

        // Find paths between all pairs of nodes
        let pairs = generatePairs(from: nodeIds)
        for (sourceId, targetId) in pairs {
            let sourceLabel = nodeLabels[sourceId] ?? "Node \(sourceId)"
            let targetLabel = nodeLabels[targetId] ?? "Node \(targetId)"

            let sourceEdges = index.nodeToEdges[sourceId] ?? []
            let targetEdges = index.nodeToEdges[targetId] ?? []

            guard !sourceEdges.isEmpty && !targetEdges.isEmpty else {
                logger.debug("No edges for pair: \(sourceLabel) - \(targetLabel)")
                continue
            }

            let paths = findShortestPaths(
                from: sourceEdges,
                to: targetEdges,
                index: index,
                intersectionThreshold: intersectionThreshold,
                maxPaths: maxPaths
            )

            for edgePath in paths {
                let hops = buildHops(for: edgePath, index: index)
                let edgeMembers = buildEdgeMembers(for: edgePath, index: index)

                reports.append(PathReport(
                    pair: (sourceLabel, targetLabel),
                    edgePath: edgePath,
                    hops: hops,
                    edgeMembers: edgeMembers
                ))
            }
        }

        logger.info("Found \(reports.count) paths between \(pairs.count) node pairs")
        return reports
    }

    // MARK: - Hypergraph Index

    /// In-memory index for efficient hypergraph traversal.
    private struct HypergraphIndex {
        /// Maps node ID to set of edge IDs containing that node
        var nodeToEdges: [Int64: Set<Int64>] = [:]
        /// Maps edge ID to set of node IDs in that edge
        var edgeToNodes: [Int64: Set<Int64>] = [:]
        /// Maps node ID to label
        var nodeLabels: [Int64: String] = [:]
    }

    /// Builds an in-memory index of the hypergraph for efficient BFS.
    private func buildHypergraphIndex() throws -> HypergraphIndex {
        try database.read { db in
            var index = HypergraphIndex()

            // Load all incidences
            let sql = """
                SELECT hi.edge_id, hi.node_id, hn.label
                FROM hypergraph_incidence hi
                JOIN hypergraph_node hn ON hi.node_id = hn.id
            """

            let rows = try Row.fetchAll(db, sql: sql)

            for row in rows {
                let edgeId: Int64 = row["edge_id"]
                let nodeId: Int64 = row["node_id"]
                let label: String = row["label"]

                index.nodeToEdges[nodeId, default: []].insert(edgeId)
                index.edgeToNodes[edgeId, default: []].insert(nodeId)
                index.nodeLabels[nodeId] = label
            }

            return index
        }
    }

    // MARK: - BFS Path Finding

    /// Finds shortest paths between two sets of edges using BFS.
    private func findShortestPaths(
        from sourceEdges: Set<Int64>,
        to targetEdges: Set<Int64>,
        index: HypergraphIndex,
        intersectionThreshold: Int,
        maxPaths: Int
    ) -> [[Int64]] {
        guard !sourceEdges.isEmpty && !targetEdges.isEmpty else { return [] }

        // BFS state
        var queue: [(edge: Int64, depth: Int)] = []
        var depth: [Int64: Int] = [:]
        var parents: [Int64: [Int64]] = [:]
        var pathsFound: [[Int64]] = []
        var minDepthFound: Int?

        // Initialize queue with source edges
        for edge in sourceEdges {
            queue.append((edge, 0))
            depth[edge] = 0
        }

        var queueIndex = 0
        while queueIndex < queue.count && pathsFound.count < maxPaths {
            let (currentEdge, currentDepth) = queue[queueIndex]
            queueIndex += 1

            // Check if we reached a target edge
            if targetEdges.contains(currentEdge) {
                if minDepthFound == nil {
                    minDepthFound = currentDepth
                }

                if currentDepth == minDepthFound {
                    // Reconstruct all paths to this edge
                    let newPaths = reconstructPaths(to: currentEdge, parents: parents)
                    for path in newPaths {
                        pathsFound.append(path)
                        if pathsFound.count >= maxPaths {
                            return pathsFound
                        }
                    }
                } else if currentDepth > minDepthFound! {
                    // We've gone past the shortest path depth
                    break
                }
            }

            // Expand to neighboring edges
            let neighbors = findNeighborEdges(
                of: currentEdge,
                index: index,
                intersectionThreshold: intersectionThreshold
            )

            for neighborEdge in neighbors {
                let neighborDepth = currentDepth + 1

                if depth[neighborEdge] == nil {
                    // First discovery
                    depth[neighborEdge] = neighborDepth
                    parents[neighborEdge, default: []].append(currentEdge)
                    queue.append((neighborEdge, neighborDepth))
                } else if depth[neighborEdge] == neighborDepth {
                    // Alternative parent at same depth (for k-paths)
                    parents[neighborEdge, default: []].append(currentEdge)
                }
            }
        }

        return pathsFound
    }

    /// Finds edges that share at least `threshold` nodes with the given edge.
    private func findNeighborEdges(
        of edge: Int64,
        index: HypergraphIndex,
        intersectionThreshold: Int
    ) -> Set<Int64> {
        guard let edgeNodes = index.edgeToNodes[edge] else { return [] }

        var neighbors: Set<Int64> = []

        // Find all edges that share nodes with this edge
        for nodeId in edgeNodes {
            if let adjacentEdges = index.nodeToEdges[nodeId] {
                for adjacentEdge in adjacentEdges where adjacentEdge != edge {
                    // Check intersection threshold
                    if let adjacentNodes = index.edgeToNodes[adjacentEdge] {
                        let intersection = edgeNodes.intersection(adjacentNodes)
                        if intersection.count >= intersectionThreshold {
                            neighbors.insert(adjacentEdge)
                        }
                    }
                }
            }
        }

        return neighbors
    }

    /// Reconstructs all paths to an edge using parent pointers.
    private func reconstructPaths(to edge: Int64, parents: [Int64: [Int64]]) -> [[Int64]] {
        guard let edgeParents = parents[edge], !edgeParents.isEmpty else {
            return [[edge]]
        }

        var allPaths: [[Int64]] = []
        for parent in edgeParents {
            let parentPaths = reconstructPaths(to: parent, parents: parents)
            for var path in parentPaths {
                path.append(edge)
                allPaths.append(path)
            }
        }

        return allPaths
    }

    // MARK: - Report Building

    /// Builds hop information for a path.
    private func buildHops(for edgePath: [Int64], index: HypergraphIndex) -> [PathHop] {
        guard edgePath.count >= 2 else { return [] }

        var hops: [PathHop] = []

        for i in 0..<(edgePath.count - 1) {
            let fromEdge = edgePath[i]
            let toEdge = edgePath[i + 1]

            let fromNodes = index.edgeToNodes[fromEdge] ?? []
            let toNodes = index.edgeToNodes[toEdge] ?? []
            let intersection = fromNodes.intersection(toNodes)

            let intersectionLabels = intersection.compactMap { index.nodeLabels[$0] }

            hops.append(PathHop(
                fromEdge: fromEdge,
                toEdge: toEdge,
                intersectionNodes: intersectionLabels
            ))
        }

        return hops
    }

    /// Builds edge membership information for a path.
    private func buildEdgeMembers(for edgePath: [Int64], index: HypergraphIndex) -> [Int64: [String]] {
        var members: [Int64: [String]] = [:]

        for edgeId in edgePath {
            if let nodeIds = index.edgeToNodes[edgeId] {
                members[edgeId] = nodeIds.compactMap { index.nodeLabels[$0] }
            }
        }

        return members
    }

    // MARK: - Helpers

    /// Generates all unique pairs from a list of node IDs.
    private func generatePairs(from nodeIds: [Int64]) -> [(Int64, Int64)] {
        var pairs: [(Int64, Int64)] = []
        for i in 0..<nodeIds.count {
            for j in (i + 1)..<nodeIds.count {
                pairs.append((nodeIds[i], nodeIds[j]))
            }
        }
        return pairs
    }

    /// Fetches node labels for the given node IDs.
    private func fetchNodeLabels(for nodeIds: [Int64]) throws -> [Int64: String] {
        guard !nodeIds.isEmpty else { return [:] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let sql = "SELECT id, label FROM hypergraph_node WHERE id IN (\(placeholders))"

            var labels: [Int64: String] = [:]
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(nodeIds))
            for row in rows {
                labels[row["id"]] = row["label"]
            }
            return labels
        }
    }
}
