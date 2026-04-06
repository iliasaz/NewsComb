import Foundation
import GRDB
import MCP

/// Gets detailed information about a specific theme cluster.
enum MCPGetThemeDetailsTool {
    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.shared) throws -> String {
        guard let clusterId = arguments["cluster_id"]?.intValue else {
            throw MCPToolError.missingParameter("cluster_id")
        }

        return try database.read { db -> String in
            guard let cluster = try Row.fetchOne(db, sql: """
                SELECT cluster_id, label, size, summary,
                       top_entities_json, top_rel_families_json
                FROM clusters
                WHERE cluster_id = ?
            """, arguments: [clusterId]) else {
                throw MCPToolError.notFound("Theme cluster \(clusterId) not found. Use get_themes to list available clusters.")
            }

            let label: String? = cluster["label"]
            let size: Int = cluster["size"]
            let summary: String? = cluster["summary"]
            let topEntitiesJson: String? = cluster["top_entities_json"]
            let topRelFamiliesJson: String? = cluster["top_rel_families_json"]

            var output = "## \(label ?? "Theme \(clusterId)")\n"
            output += "Size: \(size) events\n\n"

            if let summary, !summary.isEmpty {
                output += "### Summary\n\(summary)\n\n"
            }

            if let json = topEntitiesJson,
               let data = json.data(using: .utf8),
               let entities = try? JSONDecoder().decode([MCPRankedEntity].self, from: data),
               !entities.isEmpty {
                output += "### Top Entities\n"
                for entity in entities.prefix(10) {
                    output += "- \(entity.label) (score: \(entity.score, format: .number.precision(.fractionLength(2))))\n"
                }
                output += "\n"
            }

            if let json = topRelFamiliesJson,
               let data = json.data(using: .utf8),
               let families = try? JSONDecoder().decode([MCPRankedFamily].self, from: data),
               !families.isEmpty {
                output += "### Relationship Types\n"
                for family in families {
                    output += "- \(family.family): \(family.count) events\n"
                }
                output += "\n"
            }

            let exemplars = try Row.fetchAll(db, sql: """
                SELECT ce.rank, he.label AS edge_label,
                       GROUP_CONCAT(CASE WHEN hi.role = 'source' THEN hn.label END, ', ') AS sources,
                       GROUP_CONCAT(CASE WHEN hi.role = 'target' THEN hn.label END, ', ') AS targets
                FROM cluster_exemplars ce
                JOIN hypergraph_edge he ON ce.event_id = he.id
                JOIN hypergraph_incidence hi ON he.id = hi.edge_id
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                WHERE ce.cluster_id = ?
                GROUP BY ce.event_id
                ORDER BY ce.rank ASC
                LIMIT 10
            """, arguments: [clusterId])

            if !exemplars.isEmpty {
                output += "### Exemplar Events\n"
                for row in exemplars {
                    let edgeLabel: String = row["edge_label"]
                    let sources: String? = row["sources"]
                    let targets: String? = row["targets"]
                    let targetList = targets ?? ""
                    if targetList.isEmpty {
                        output += "- \(sources ?? "?") **\(edgeLabel)**\n"
                    } else {
                        output += "- \(sources ?? "?") **\(edgeLabel)** \(targetList)\n"
                    }
                }
                output += "\n"
            }

            let articles = try Row.fetchAll(db, sql: """
                SELECT DISTINCT fi.title, fi.link, rs.title AS source_name
                FROM cluster_members cm
                JOIN hypergraph_edge he ON cm.event_id = he.id
                JOIN article_edge_provenance aep ON he.id = aep.edge_id
                JOIN feed_item fi ON aep.feed_item_id = fi.id
                LEFT JOIN rss_source rs ON fi.source_id = rs.id
                WHERE cm.cluster_id = ?
                LIMIT 10
            """, arguments: [clusterId])

            if !articles.isEmpty {
                output += "### Source Articles\n"
                for row in articles {
                    let title: String = row["title"]
                    let link: String? = row["link"]
                    let sourceName: String? = row["source_name"]
                    output += "- \(title)"
                    if let sourceName { output += " (\(sourceName))" }
                    if let link { output += " — \(link)" }
                    output += "\n"
                }
            }

            return output
        }
    }
}
