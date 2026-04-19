import Foundation
import GRDB
import MCP

/// Lists every theme an entity participates in, ranked by how many of the entity's
/// edges fall into each theme. Answers questions like "which story themes is OpenAI
/// involved in, and which is the most prominent?"
enum MCPGetEntityThemesTool {
    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.shared) throws -> String {
        guard let entityLabel = arguments["entity_label"]?.stringValue, !entityLabel.isEmpty else {
            throw MCPToolError.missingParameter("entity_label")
        }
        let limit = arguments["limit"]?.intValue ?? 20

        return try database.read { db -> String in
            // Resolve the entity (case-insensitive) — pick the best DF match if multiple share a label.
            guard let nodeRow = try Row.fetchOne(db, sql: """
                SELECT id, label, COALESCE(node_type, 'unclassified') AS node_type, df
                FROM hypergraph_node
                WHERE LOWER(label) = LOWER(?)
                ORDER BY df DESC
                LIMIT 1
            """, arguments: [entityLabel]) else {
                return "No entity found with label '\(entityLabel)'. Try search_concepts to find candidates."
            }

            let nodeId: Int64 = nodeRow["id"]
            let resolvedLabel: String = nodeRow["label"]
            let nodeType: String = nodeRow["node_type"]
            let df: Int = nodeRow["df"]

            // Count edges per cluster involving this entity, plus aggregate membership.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    cm.cluster_id,
                    c.label AS cluster_label,
                    c.size AS cluster_size,
                    c.summary,
                    COUNT(DISTINCT cm.event_id) AS edge_count,
                    AVG(cm.membership) AS avg_membership
                FROM hypergraph_incidence hi
                JOIN cluster_members cm ON cm.event_id = hi.edge_id
                JOIN clusters c ON c.cluster_id = cm.cluster_id
                WHERE hi.node_id = ?
                GROUP BY cm.cluster_id
                ORDER BY edge_count DESC
                LIMIT ?
            """, arguments: [nodeId, limit])

            var output = "## Themes involving '\(resolvedLabel)'\n"
            output += "Entity type: \(nodeType), document frequency: \(df)\n\n"

            guard !rows.isEmpty else {
                return output + "This entity does not currently appear in any theme cluster. It may belong to events that were classified as noise, or themes have not been built yet."
            }

            output += "Found \(rows.count) theme(s) where this entity participates.\n\n"
            for row in rows {
                let cid: Int64 = row["cluster_id"]
                let cl: String? = row["cluster_label"]
                let csize: Int = row["cluster_size"]
                let edgeCount: Int = row["edge_count"]
                let avgMem: Double? = row["avg_membership"]
                let summary: String? = row["summary"]

                output += "### \(cl ?? "Theme \(cid)") (cluster_id=\(cid))\n"
                output += "- Theme size: \(csize) events; entity appears in \(edgeCount) of them"
                if let avgMem {
                    output += " (avg membership \(avgMem.formatted(.number.precision(.fractionLength(2)))))"
                }
                output += "\n"
                if let summary, !summary.isEmpty {
                    output += "- \(summary)\n"
                }
                output += "\n"
            }
            return output
        }
    }
}
