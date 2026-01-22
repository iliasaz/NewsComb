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
    ///   - maxDepth: Maximum BFS depth (path length = depth + 1). Higher values find longer paths but take more time.
    /// - Returns: Array of path reports
    func findPaths(
        between nodeIds: [Int64],
        intersectionThreshold: Int = 1,
        maxPaths: Int = 3,
        maxDepth: Int = 4
    ) throws -> [PathReport] {
        guard nodeIds.count >= 2 else { return [] }

        // Build the hypergraph index with precomputed edge adjacency
        let index = try buildHypergraphIndex(intersectionThreshold: intersectionThreshold)
        logger.info("Built hypergraph index: \(index.nodeToEdges.count) nodes, \(index.edgeToNodes.count) edges")

        // Get node labels for reporting
        let nodeLabels = try fetchNodeLabels(for: nodeIds)

        let bfsStartTime = ContinuousClock.now

        // Use multi-source BFS: ONE traversal finds paths for ALL pairs
        let (reports, edgesExplored) = findAllPairsPaths(
            nodeIds: nodeIds,
            nodeLabels: nodeLabels,
            index: index,
            maxPaths: maxPaths,
            maxDepth: maxDepth
        )

        let totalTime = ContinuousClock.now - bfsStartTime
        let pairs = generatePairs(from: nodeIds)
        logger.info("""
            Multi-source BFS: \(pairs.count) pairs, \(reports.count) paths found
            Total time: \(totalTime), edges explored: \(edgesExplored)
            """)

        // Log path length distribution for debugging
        let pathLengths = reports.map { $0.edgePath.count }
        let lengthCounts = Dictionary(grouping: pathLengths, by: { $0 }).mapValues { $0.count }
        let sortedLengths = lengthCounts.sorted { $0.key < $1.key }
        let lengthSummary = sortedLengths.map { "length \($0.key): \($0.value)" }.joined(separator: ", ")
        logger.info("Found \(reports.count) paths between \(pairs.count) node pairs. Distribution: \(lengthSummary)")
        return reports
    }

    // MARK: - Hypergraph Index

    /// In-memory index for efficient hypergraph traversal.
    /// Uses array-based storage for O(1) lookups without hashing overhead.
    private struct HypergraphIndex {
        /// Maps node ID to set of edge IDs containing that node
        var nodeToEdges: [Int64: Set<Int64>] = [:]
        /// Maps edge ID to set of node IDs in that edge
        var edgeToNodes: [Int64: Set<Int64>] = [:]
        /// Maps node ID to label
        var nodeLabels: [Int64: String] = [:]

        /// Precomputed edge adjacency: maps edge ID to adjacent edge IDs (s-connected)
        var edgeAdjacency: [Int64: Set<Int64>] = [:]
    }

    /// Builds an in-memory index of the hypergraph for efficient BFS.
    /// Precomputes edge adjacency and builds array-based structures for fast lookups.
    private func buildHypergraphIndex(intersectionThreshold: Int = 1) throws -> HypergraphIndex {
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

            // Precompute edge adjacency (s-connectivity)
            logger.info("Precomputing edge adjacency for \(index.edgeToNodes.count) edges...")
            let startTime = ContinuousClock.now

            for (edgeId, edgeNodes) in index.edgeToNodes {
                var adjacentEdges: Set<Int64> = []

                // Find all edges that share >= threshold nodes with this edge
                for nodeId in edgeNodes {
                    if let candidateEdges = index.nodeToEdges[nodeId] {
                        for candidateEdge in candidateEdges where candidateEdge != edgeId {
                            guard !adjacentEdges.contains(candidateEdge) else { continue }

                            if let candidateNodes = index.edgeToNodes[candidateEdge] {
                                let intersectionCount = edgeNodes.intersection(candidateNodes).count
                                if intersectionCount >= intersectionThreshold {
                                    adjacentEdges.insert(candidateEdge)
                                }
                            }
                        }
                    }
                }

                index.edgeAdjacency[edgeId] = adjacentEdges
            }

            let elapsed = ContinuousClock.now - startTime
            let totalAdjacency = index.edgeAdjacency.values.reduce(0) { $0 + $1.count }
            let avgAdjacency = totalAdjacency / max(1, index.edgeAdjacency.count)
            logger.info("Edge adjacency computed in \(elapsed). Average adjacency: \(avgAdjacency) edges")

            return index
        }
    }

    // MARK: - Multi-Source BFS Path Finding

    /// Finds paths between all pairs of nodes using a SINGLE multi-source BFS traversal.
    /// This is ~100x faster than running separate BFS for each pair.
    private func findAllPairsPaths(
        nodeIds: [Int64],
        nodeLabels: [Int64: String],
        index: HypergraphIndex,
        maxPaths: Int,
        maxDepth: Int
    ) -> (reports: [PathReport], edgesExplored: Int) {
        // Map each node to the edges containing it
        var nodeToEdgesMap: [Int64: Set<Int64>] = [:]
        for nodeId in nodeIds {
            nodeToEdgesMap[nodeId] = index.nodeToEdges[nodeId] ?? []
        }

        // Map each edge to which query nodes it contains
        var edgeToQueryNodes: [Int64: Set<Int64>] = [:]
        for nodeId in nodeIds {
            for edgeId in nodeToEdgesMap[nodeId] ?? [] {
                edgeToQueryNodes[edgeId, default: []].insert(nodeId)
            }
        }

        // Collect all starting edges (edges containing any query node)
        let allStartingEdges = Set(edgeToQueryNodes.keys)
        guard !allStartingEdges.isEmpty else { return ([], 0) }

        logger.info("Multi-source BFS: \(nodeIds.count) query nodes, \(allStartingEdges.count) starting edges")

        // BFS state: track reachability from each source node
        // reachableFrom[edge] = set of source nodes that can reach this edge
        var reachableFrom: [Int64: Set<Int64>] = [:]
        var visited: [Int64: Int] = [:]  // edge -> depth
        var parents: [Int64: [Int64: Int64]] = [:]  // edge -> [sourceNode -> parentEdge]
        var queue: [(edge: Int64, depth: Int)] = []
        var edgesExplored = 0

        // Initialize: each starting edge is reachable from the nodes it contains
        for (edgeId, queryNodes) in edgeToQueryNodes {
            reachableFrom[edgeId] = queryNodes
            visited[edgeId] = 0
            queue.append((edgeId, 0))
            // No parent for starting edges
            parents[edgeId] = [:]
            for nodeId in queryNodes {
                parents[edgeId]?[nodeId] = -1  // -1 indicates source edge
            }
        }

        // Track found paths: (sourceNode, targetNode) -> [paths]
        var foundPaths: [Int64: [Int64: [[Int64]]]] = [:]
        var pathCountPerPair: [Int64: [Int64: Int]] = [:]
        var pathsFoundCount = 0

        // BFS traversal
        var queueIndex = 0
        while queueIndex < queue.count {
            let (currentEdge, currentDepth) = queue[queueIndex]
            queueIndex += 1
            edgesExplored += 1

            if currentDepth > maxDepth {
                continue  // Don't break, process other edges at lower depths
            }

            // Check if this edge connects any source-target pairs
            let currentQueryNodes = edgeToQueryNodes[currentEdge] ?? []
            let reachableSources = reachableFrom[currentEdge] ?? []

            // For each query node in this edge, check if it's a target for any reachable source
            for targetNode in currentQueryNodes {
                for sourceNode in reachableSources where sourceNode != targetNode {
                    // Check if we already have enough paths for this pair
                    let existingCount = pathCountPerPair[sourceNode]?[targetNode] ?? 0
                    if existingCount >= maxPaths { continue }

                    // Check if this is the shortest path (or equal to shortest)
                    if let existingPaths = foundPaths[sourceNode]?[targetNode],
                       let firstPath = existingPaths.first,
                       firstPath.count < currentDepth + 1 {
                        continue  // We already have shorter paths
                    }

                    // Reconstruct path from sourceNode to this edge
                    let path = reconstructMultiSourcePath(
                        to: currentEdge,
                        sourceNode: sourceNode,
                        parents: parents
                    )

                    if !path.isEmpty {
                        foundPaths[sourceNode, default: [:]][targetNode, default: []].append(path)
                        pathCountPerPair[sourceNode, default: [:]][targetNode, default: 0] += 1
                        pathsFoundCount += 1
                    }
                }
            }

            // Expand to neighbors
            let neighbors = index.edgeAdjacency[currentEdge] ?? []
            let neighborDepth = currentDepth + 1

            for neighborEdge in neighbors {
                let wasVisited = visited[neighborEdge] != nil
                let previousDepth = visited[neighborEdge] ?? Int.max

                if !wasVisited {
                    // First visit to this edge
                    visited[neighborEdge] = neighborDepth
                    reachableFrom[neighborEdge] = reachableSources
                    parents[neighborEdge] = [:]
                    for sourceNode in reachableSources {
                        parents[neighborEdge]?[sourceNode] = currentEdge
                    }
                    queue.append((neighborEdge, neighborDepth))
                } else {
                    // Already visited - but we may have NEW reachability info to add
                    // This happens when an edge is reachable from multiple starting points
                    let existingReachable = reachableFrom[neighborEdge] ?? []
                    let newSources = reachableSources.subtracting(existingReachable)

                    if !newSources.isEmpty {
                        // Add new reachability sources with their parent info
                        reachableFrom[neighborEdge]?.formUnion(newSources)
                        for newSource in newSources {
                            parents[neighborEdge]?[newSource] = currentEdge
                        }

                        // IMPORTANT: Check for new paths NOW since we have new reachability
                        // This handles the case where the target edge was visited earlier
                        let neighborQueryNodes = edgeToQueryNodes[neighborEdge] ?? []
                        for newSource in newSources {
                            for targetNode in neighborQueryNodes where targetNode != newSource {
                                let existingCount = pathCountPerPair[newSource]?[targetNode] ?? 0
                                if existingCount >= maxPaths { continue }

                                let path = reconstructMultiSourcePath(
                                    to: neighborEdge,
                                    sourceNode: newSource,
                                    parents: parents
                                )
                                if !path.isEmpty {
                                    foundPaths[newSource, default: [:]][targetNode, default: []].append(path)
                                    pathCountPerPair[newSource, default: [:]][targetNode, default: 0] += 1
                                    pathsFoundCount += 1
                                }
                            }
                        }
                    }
                }
            }
        }

        logger.info("Multi-source BFS complete: \(pathsFoundCount) paths found")

        // Build reports from found paths
        var reports: [PathReport] = []
        for (sourceNode, targetPaths) in foundPaths {
            let sourceLabel = nodeLabels[sourceNode] ?? "Node \(sourceNode)"
            for (targetNode, paths) in targetPaths {
                let targetLabel = nodeLabels[targetNode] ?? "Node \(targetNode)"
                for path in paths.prefix(maxPaths) {
                    let hops = buildHops(for: path, index: index)
                    let edgeMembers = buildEdgeMembers(for: path, index: index)
                    reports.append(PathReport(
                        pair: (sourceLabel, targetLabel),
                        edgePath: path,
                        hops: hops,
                        edgeMembers: edgeMembers
                    ))
                }
            }
        }

        return (reports, edgesExplored)
    }

    /// Reconstructs a path from a source node to an edge using multi-source parent pointers.
    private func reconstructMultiSourcePath(
        to edge: Int64,
        sourceNode: Int64,
        parents: [Int64: [Int64: Int64]]
    ) -> [Int64] {
        var path: [Int64] = []
        var currentEdge = edge

        while true {
            path.append(currentEdge)
            guard let edgeParents = parents[currentEdge],
                  let parentEdge = edgeParents[sourceNode] else {
                break
            }
            if parentEdge == -1 {
                // Reached source edge
                break
            }
            currentEdge = parentEdge
        }

        return path.reversed()
    }

    // MARK: - Single-Pair BFS (kept for reference)

    /// Finds shortest paths between two sets of edges using BFS with statistics.
    /// Returns the paths found and the number of edges explored.
    private func findShortestPathsWithStats(
        from sourceEdges: Set<Int64>,
        to targetEdges: Set<Int64>,
        index: HypergraphIndex,
        intersectionThreshold: Int,
        maxPaths: Int,
        maxDepth: Int
    ) -> (paths: [[Int64]], edgesExplored: Int) {
        guard !sourceEdges.isEmpty && !targetEdges.isEmpty else { return ([], 0) }

        // BFS state using dictionaries
        var queue: [(edge: Int64, depth: Int)] = []
        var visited: [Int64: Int] = [:]
        var parents: [Int64: [Int64]] = [:]
        var pathsFound: [[Int64]] = []
        var minDepthFound: Int?
        var edgesExplored = 0

        // Initialize queue with source edges
        for edge in sourceEdges {
            queue.append((edge, 0))
            visited[edge] = 0
        }

        var queueIndex = 0
        while queueIndex < queue.count && pathsFound.count < maxPaths {
            let (currentEdge, currentDepth) = queue[queueIndex]
            queueIndex += 1
            edgesExplored += 1

            if currentDepth > maxDepth {
                break
            }

            // Check if we reached a target edge
            if targetEdges.contains(currentEdge) {
                if minDepthFound == nil {
                    minDepthFound = currentDepth
                }

                if currentDepth == minDepthFound {
                    let newPaths = reconstructPaths(to: currentEdge, parents: parents)
                    for path in newPaths {
                        pathsFound.append(path)
                        if pathsFound.count >= maxPaths {
                            return (pathsFound, edgesExplored)
                        }
                    }
                } else if currentDepth > minDepthFound! {
                    break
                }
            }

            // Expand to neighboring edges
            let neighbors = index.edgeAdjacency[currentEdge] ?? []
            let neighborDepth = currentDepth + 1

            for neighborEdge in neighbors {
                if visited[neighborEdge] == nil {
                    visited[neighborEdge] = neighborDepth
                    parents[neighborEdge, default: []].append(currentEdge)
                    queue.append((neighborEdge, neighborDepth))
                } else if visited[neighborEdge] == neighborDepth {
                    parents[neighborEdge, default: []].append(currentEdge)
                }
            }
        }

        return (pathsFound, edgesExplored)
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
