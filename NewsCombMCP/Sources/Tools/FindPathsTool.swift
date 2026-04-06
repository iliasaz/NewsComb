import Foundation
import GRDB
import MCP

/// Finds multi-hop reasoning paths between two concepts in the hypergraph.
///
/// Uses BFS over the hypergraph's edge adjacency (s-connectivity):
/// two edges are adjacent if they share at least one node.
enum FindPathsTool {
    static func run(arguments: [String: Value], database: ReadOnlyDatabase) throws -> String {
        guard let source = arguments["source"]?.stringValue, !source.isEmpty else {
            throw ToolError.missingParameter("source")
        }
        guard let target = arguments["target"]?.stringValue, !target.isEmpty else {
            throw ToolError.missingParameter("target")
        }
        let maxDepth = arguments["max_depth"]?.intValue ?? 4
        let maxPaths = arguments["max_paths"]?.intValue ?? 3

        let result = try database.read { db -> String in
            // Find source and target node IDs
            guard let sourceNode = try Row.fetchOne(db, sql: """
                SELECT id, label FROM hypergraph_node WHERE LOWER(label) = LOWER(?)
            """, arguments: [source]) else {
                throw ToolError.notFound("Source concept '\(source)' not found. Use search_concepts to find the correct label.")
            }
            guard let targetNode = try Row.fetchOne(db, sql: """
                SELECT id, label FROM hypergraph_node WHERE LOWER(label) = LOWER(?)
            """, arguments: [target]) else {
                throw ToolError.notFound("Target concept '\(target)' not found. Use search_concepts to find the correct label.")
            }

            let sourceId: Int64 = sourceNode["id"]
            let targetId: Int64 = targetNode["id"]
            let sourceLabel: String = sourceNode["label"]
            let targetLabel: String = targetNode["label"]

            // Build hypergraph index: node → edges, edge → nodes
            var nodeToEdges: [Int64: Set<Int64>] = [:]
            var edgeToNodes: [Int64: Set<Int64>] = [:]
            var nodeLabels: [Int64: String] = [:]
            var edgeLabels: [Int64: String] = [:]

            let incidenceRows = try Row.fetchAll(db, sql: """
                SELECT hi.edge_id, hi.node_id, hn.label AS node_label, he.label AS edge_label
                FROM hypergraph_incidence hi
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                JOIN hypergraph_edge he ON hi.edge_id = he.id
            """)

            for row in incidenceRows {
                let edgeId: Int64 = row["edge_id"]
                let nodeId: Int64 = row["node_id"]
                let nodeLabel: String = row["node_label"]
                let edgeLabel: String = row["edge_label"]

                nodeToEdges[nodeId, default: []].insert(edgeId)
                edgeToNodes[edgeId, default: []].insert(nodeId)
                nodeLabels[nodeId] = nodeLabel
                edgeLabels[edgeId] = edgeLabel
            }

            // Precompute edge adjacency (edges sharing at least one node)
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

            // BFS from source edges to target edges
            let sourceEdges = nodeToEdges[sourceId] ?? []
            let targetEdges = nodeToEdges[targetId] ?? []

            guard !sourceEdges.isEmpty else {
                return "No edges found for '\(sourceLabel)'. This concept may not have any relationships."
            }
            guard !targetEdges.isEmpty else {
                return "No edges found for '\(targetLabel)'. This concept may not have any relationships."
            }

            var queue: [(edge: Int64, depth: Int)] = []
            var visited: [Int64: Int] = [:]
            var parents: [Int64: [Int64]] = [:]
            var pathsFound: [[Int64]] = []
            var minDepthFound: Int?

            for edge in sourceEdges {
                queue.append((edge, 0))
                visited[edge] = 0
            }

            var queueIndex = 0
            while queueIndex < queue.count && pathsFound.count < maxPaths {
                let (currentEdge, currentDepth) = queue[queueIndex]
                queueIndex += 1

                if currentDepth > maxDepth { break }

                // Check if we reached a target edge
                if targetEdges.contains(currentEdge) {
                    if minDepthFound == nil {
                        minDepthFound = currentDepth
                    }
                    if currentDepth == minDepthFound {
                        let paths = reconstructPaths(to: currentEdge, parents: parents)
                        for path in paths {
                            pathsFound.append(path)
                            if pathsFound.count >= maxPaths { break }
                        }
                    } else if currentDepth > (minDepthFound ?? Int.max) {
                        break
                    }
                }

                // Expand neighbors
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

            // Format results
            guard !pathsFound.isEmpty else {
                return "No path found between '\(sourceLabel)' and '\(targetLabel)' within \(maxDepth) hops. They may not be connected in the knowledge graph."
            }

            var output = "Found \(pathsFound.count) path(s) between **\(sourceLabel)** and **\(targetLabel)**:\n\n"

            for (pathIndex, edgePath) in pathsFound.enumerated() {
                output += "### Path \(pathIndex + 1) (\(edgePath.count) hop\(edgePath.count == 1 ? "" : "s"))\n"

                // Build a readable path: show edge labels and connecting nodes
                for (i, edgeId) in edgePath.enumerated() {
                    let label = edgeLabels[edgeId] ?? "?"
                    let nodes = edgeToNodes[edgeId] ?? []
                    let nodeNames = nodes.compactMap { nodeLabels[$0] }.sorted()

                    output += "\(i + 1). **\(label)** — participants: \(nodeNames.joined(separator: ", "))\n"

                    // Show connecting node between consecutive edges
                    if i < edgePath.count - 1 {
                        let nextEdgeNodes = edgeToNodes[edgePath[i + 1]] ?? []
                        let shared = nodes.intersection(nextEdgeNodes)
                        let sharedNames = shared.compactMap { nodeLabels[$0] }
                        if !sharedNames.isEmpty {
                            output += "   ↓ via: \(sharedNames.joined(separator: ", "))\n"
                        }
                    }
                }
                output += "\n"
            }

            return output
        }

        return result
    }

    /// Reconstructs all paths from source edges to the given edge using parent pointers.
    private static func reconstructPaths(to edge: Int64, parents: [Int64: [Int64]]) -> [[Int64]] {
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
}
