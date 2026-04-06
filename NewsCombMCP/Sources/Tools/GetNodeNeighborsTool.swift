import Foundation
import GRDB
import MCP

/// Gets all edges (relationships) connected to a node, showing neighbors and provenance.
enum GetNodeNeighborsTool {
    static func run(arguments: [String: Value], database: ReadOnlyDatabase) throws -> String {
        guard let nodeLabel = arguments["node_label"]?.stringValue, !nodeLabel.isEmpty else {
            throw ToolError.missingParameter("node_label")
        }
        let limit = arguments["limit"]?.intValue ?? 30

        let (node, edges) = try database.read { db -> (Row?, [Row]) in
            // Find the node (case-insensitive)
            let nodeRow = try Row.fetchOne(db, sql: """
                SELECT id, label, node_type, df, idf
                FROM hypergraph_node
                WHERE LOWER(label) = LOWER(?)
            """, arguments: [nodeLabel])

            guard let nodeRow else {
                return (nil, [])
            }

            let nodeId: Int64 = nodeRow["id"]

            // Get edges connected to this node with all participant nodes
            let edgeRows = try Row.fetchAll(db, sql: """
                SELECT DISTINCT
                    he.id AS edge_id,
                    he.label AS edge_label,
                    GROUP_CONCAT(
                        CASE WHEN hi2.role = 'source' THEN hn2.label END, ', '
                    ) AS source_nodes,
                    GROUP_CONCAT(
                        CASE WHEN hi2.role = 'target' THEN hn2.label END, ', '
                    ) AS target_nodes,
                    aep.chunk_text AS provenance
                FROM hypergraph_incidence hi
                JOIN hypergraph_edge he ON hi.edge_id = he.id
                JOIN hypergraph_incidence hi2 ON he.id = hi2.edge_id
                JOIN hypergraph_node hn2 ON hi2.node_id = hn2.id
                LEFT JOIN article_edge_provenance aep ON he.id = aep.edge_id
                WHERE hi.node_id = ?
                GROUP BY he.id, aep.chunk_text
                ORDER BY he.created_at DESC
                LIMIT ?
            """, arguments: [nodeId, limit])

            return (nodeRow, edgeRows)
        }

        guard let node else {
            throw ToolError.notFound("No concept found matching '\(nodeLabel)'. Try search_concepts to find the exact label.")
        }

        let label: String = node["label"]
        let nodeType: String? = node["node_type"]
        let df: Int? = node["df"]

        var output = "## \(label)"
        if let nodeType {
            output += " (\(nodeType))"
        }
        if let df, df > 0 {
            output += " — \(df) events"
        }
        output += "\n\n"

        guard !edges.isEmpty else {
            output += "No relationships found for this concept.\n"
            return output
        }

        output += "\(edges.count) relationship(s):\n\n"

        for row in edges {
            let edgeLabel: String = row["edge_label"]
            let sources: String? = row["source_nodes"]
            let targets: String? = row["target_nodes"]
            let provenance: String? = row["provenance"]

            let sourceList = sources ?? "?"
            let targetList = targets ?? "?"

            output += "- \(sourceList) **\(edgeLabel)** \(targetList)\n"

            if let provenance, !provenance.isEmpty {
                let truncated = provenance.count > 200
                    ? String(provenance.prefix(200)) + "..."
                    : provenance
                output += "  > \(truncated)\n"
            }
        }

        return output
    }
}
