import Foundation
import GRDB
import HyperGraphReasoning
import MCP

/// Finds multi-hop reasoning paths between two concepts using BFS.
/// Reuses the app's `HypergraphPathService` for the actual BFS traversal.
enum MCPFindPathsTool {
    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.shared) throws -> String {
        guard let source = arguments["source"]?.stringValue, !source.isEmpty else {
            throw MCPToolError.missingParameter("source")
        }
        guard let target = arguments["target"]?.stringValue, !target.isEmpty else {
            throw MCPToolError.missingParameter("target")
        }
        let maxDepth = arguments["max_depth"]?.intValue ?? 4
        let maxPaths = arguments["max_paths"]?.intValue ?? 3

        // Find source and target node IDs in a single read transaction for snapshot consistency
        let (sourceId, sourceLabel, targetId, targetLabel) = try database.read { db -> (Int64, String, Int64, String) in
            guard let sourceRow = try Row.fetchOne(db, sql: """
                SELECT id, label FROM hypergraph_node WHERE LOWER(label) = LOWER(?)
            """, arguments: [source]) else {
                throw MCPToolError.notFound("Source concept '\(source)' not found. Use search_concepts to find the correct label.")
            }
            guard let targetRow = try Row.fetchOne(db, sql: """
                SELECT id, label FROM hypergraph_node WHERE LOWER(label) = LOWER(?)
            """, arguments: [target]) else {
                throw MCPToolError.notFound("Target concept '\(target)' not found. Use search_concepts to find the correct label.")
            }
            return (sourceRow["id"], sourceRow["label"], targetRow["id"], targetRow["label"])
        }

        // Use the app's HypergraphPathService for BFS
        let pathService = HypergraphPathService()
        let pathReports = try pathService.findPaths(
            between: [sourceId, targetId],
            intersectionThreshold: 1,
            maxPaths: maxPaths,
            maxDepth: maxDepth
        )

        guard !pathReports.isEmpty else {
            return "No path found between '\(sourceLabel)' and '\(targetLabel)' within \(maxDepth) hops. They may not be connected in the knowledge graph."
        }

        // Fetch edge labels for formatting
        var allEdgeIds: Set<Int64> = []
        for report in pathReports {
            for edgeId in report.edgePath { allEdgeIds.insert(edgeId) }
        }

        let edgeInfo: [Int64: (label: String, nodes: [String])] = try database.read { db in
            guard !allEdgeIds.isEmpty else { return [:] }
            let placeholders = allEdgeIds.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT he.id, he.edge_id, he.label,
                       GROUP_CONCAT(hn.label, ', ') AS node_names
                FROM hypergraph_edge he
                JOIN hypergraph_incidence hi ON he.id = hi.edge_id
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                WHERE he.id IN (\(placeholders))
                GROUP BY he.id
            """, arguments: StatementArguments(Array(allEdgeIds)))

            var info: [Int64: (label: String, nodes: [String])] = [:]
            for row in rows {
                let id: Int64 = row["id"]
                let edgeIdStr: String = row["edge_id"]
                let label = ContextCollector.extractRelation(from: edgeIdStr) ?? row["label"] ?? "relates to"
                let nodeNames: String = row["node_names"] ?? ""
                info[id] = (label, nodeNames.components(separatedBy: ", ").filter { !$0.isEmpty })
            }
            return info
        }

        var output = "Found \(pathReports.count) path(s) between **\(sourceLabel)** and **\(targetLabel)**:\n\n"

        for (pathIndex, report) in pathReports.enumerated() {
            output += "### Path \(pathIndex + 1) (\(report.edgePath.count) hop\(report.edgePath.count == 1 ? "" : "s"))\n"

            for (i, edgeId) in report.edgePath.enumerated() {
                let info = edgeInfo[edgeId]
                let label = info?.label ?? "?"
                let nodes = info?.nodes ?? []

                output += "\(i + 1). **\(label)** — participants: \(nodes.joined(separator: ", "))\n"

                // Show connecting node between consecutive edges
                if i < report.edgePath.count - 1 {
                    let hop = i < report.hops.count ? report.hops[i] : nil
                    if let intersections = hop?.intersectionNodes, !intersections.isEmpty {
                        output += "   ↓ via: \(intersections.joined(separator: ", "))\n"
                    }
                }
            }
            output += "\n"
        }

        return output
    }
}
