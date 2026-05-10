import Foundation

/// Finds the top-N longest simple paths in a graph using a bounded DFS heuristic.
///
/// Longest simple path is NP-hard in general graphs, so this is a heuristic:
/// from each starting node, perform a depth-bounded DFS that tracks the
/// longest non-repeating sequence of nodes reachable. The N globally longest
/// candidates are returned (deduped by node-set membership).
enum LongestPathFinder {

    /// Compute the top `count` longest simple paths.
    ///
    /// - Parameters:
    ///   - nodes: All nodes that may appear in a path.
    ///   - edges: Edges defining adjacency. Edges are treated as undirected
    ///     and hyperedges fully connect every source to every target.
    ///   - count: Maximum number of paths to return (default 10).
    ///   - maxDepth: Maximum simple-path length to consider, in nodes.
    ///   - iterationBudget: Soft cap on total DFS recursive calls — protects
    ///     against blow-up on dense graphs.
    /// - Returns: Up to `count` paths, sorted longest-first. Each path is a
    ///   sequence of node IDs.
    static func topLongestPaths(
        nodes: [GraphNode],
        edges: [GraphEdge],
        count: Int = 10,
        maxDepth: Int = 15,
        iterationBudget: Int = 200_000
    ) -> [[Int64]] {
        guard count > 0, !nodes.isEmpty, !edges.isEmpty else { return [] }

        let adjacency = buildUndirectedAdjacency(edges: edges)
        guard !adjacency.isEmpty else { return [] }

        // Visit higher-degree nodes first — they are likelier to anchor
        // long paths, and the iteration budget is more effective when
        // promising starts run early.
        let candidateIds: [Int64] = nodes.compactMap { node in
            adjacency[node.id] != nil ? node.id : nil
        }
        let starts = candidateIds.sorted { lhs, rhs in
            let l = adjacency[lhs]?.count ?? 0
            let r = adjacency[rhs]?.count ?? 0
            return l > r
        }

        var topPaths: [[Int64]] = []
        var iterations = 0

        for startId in starts {
            if iterations >= iterationBudget { break }

            var visited: Set<Int64> = [startId]
            var currentPath: [Int64] = [startId]
            var bestPath: [Int64] = [startId]

            dfs(
                current: startId,
                adjacency: adjacency,
                visited: &visited,
                currentPath: &currentPath,
                bestPath: &bestPath,
                maxDepth: maxDepth,
                iterations: &iterations,
                iterationBudget: iterationBudget
            )

            if bestPath.count > 1 {
                insertPath(bestPath, into: &topPaths, count: count)
            }
        }

        return topPaths
    }

    /// Build undirected adjacency. Hyperedges fully connect each source-target
    /// pair, mirroring how `GraphVisualizationView` draws them.
    private static func buildUndirectedAdjacency(edges: [GraphEdge]) -> [Int64: Set<Int64>] {
        var adjacency: [Int64: Set<Int64>] = [:]
        for edge in edges {
            for source in edge.sourceNodeIds {
                for target in edge.targetNodeIds where source != target {
                    adjacency[source, default: []].insert(target)
                    adjacency[target, default: []].insert(source)
                }
            }
        }
        return adjacency
    }

    private static func dfs(
        current: Int64,
        adjacency: [Int64: Set<Int64>],
        visited: inout Set<Int64>,
        currentPath: inout [Int64],
        bestPath: inout [Int64],
        maxDepth: Int,
        iterations: inout Int,
        iterationBudget: Int
    ) {
        iterations += 1
        if iterations > iterationBudget { return }

        if currentPath.count > bestPath.count {
            bestPath = currentPath
        }

        guard currentPath.count < maxDepth else { return }
        guard let neighbors = adjacency[current] else { return }

        for neighbor in neighbors where !visited.contains(neighbor) {
            visited.insert(neighbor)
            currentPath.append(neighbor)

            dfs(
                current: neighbor,
                adjacency: adjacency,
                visited: &visited,
                currentPath: &currentPath,
                bestPath: &bestPath,
                maxDepth: maxDepth,
                iterations: &iterations,
                iterationBudget: iterationBudget
            )

            currentPath.removeLast()
            visited.remove(neighbor)
        }
    }

    /// Insert `path` into the top-N list, keeping it sorted descending by length
    /// and rejecting candidates whose node-set duplicates an existing entry.
    private static func insertPath(
        _ path: [Int64],
        into topPaths: inout [[Int64]],
        count: Int
    ) {
        let pathSet = Set(path)
        for existing in topPaths where Set(existing) == pathSet {
            return
        }

        topPaths.append(path)
        topPaths.sort { $0.count > $1.count }
        if topPaths.count > count {
            topPaths.removeLast()
        }
    }
}
