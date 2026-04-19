import Foundation
import GRDB
import MCP

/// Returns full provenance for a theme: every member event with its membership score,
/// the relationship label and participant nodes, the source article, and (optionally)
/// the chunk text the relationship was extracted from.
///
/// Complements `get_theme_details`, which only shows the top-10 exemplars.
enum MCPGetThemeProvenanceTool {
    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.shared) throws -> String {
        guard let clusterId = arguments["cluster_id"]?.intValue else {
            throw MCPToolError.missingParameter("cluster_id")
        }
        let limit = arguments["limit"]?.intValue ?? 50
        let minMembership = arguments["min_membership"]?.doubleValue ?? 0.0
        let includeChunkText = arguments["include_chunk_text"]?.boolValue ?? false
        let sourceFilter = arguments["source"]?.stringValue

        return try database.read { db -> String in
            guard let header = try Row.fetchOne(db, sql: """
                SELECT cluster_id, label, size, summary
                FROM clusters WHERE cluster_id = ?
            """, arguments: [clusterId]) else {
                throw MCPToolError.notFound("Theme cluster \(clusterId) not found.")
            }

            let label: String? = header["label"]
            let size: Int = header["size"]
            let summary: String? = header["summary"]

            // Fetch member edges joined to article + chunk provenance.
            // GROUP_CONCAT collapses incidence rows into source/target lists per edge.
            var sql = """
                SELECT
                    cm.event_id,
                    cm.membership,
                    he.label AS edge_label,
                    GROUP_CONCAT(CASE WHEN hi.role = 'source' THEN hn.label END, ', ') AS sources,
                    GROUP_CONCAT(CASE WHEN hi.role = 'target' THEN hn.label END, ', ') AS targets,
                    fi.id AS article_id,
                    fi.title AS article_title,
                    fi.link AS article_link,
                    rs.title AS source_name,
                    aep.chunk_index,
                    aep.chunk_text
                FROM cluster_members cm
                JOIN hypergraph_edge he ON cm.event_id = he.id
                JOIN hypergraph_incidence hi ON he.id = hi.edge_id
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                LEFT JOIN article_edge_provenance aep ON he.id = aep.edge_id
                LEFT JOIN feed_item fi ON aep.feed_item_id = fi.id
                LEFT JOIN rss_source rs ON fi.source_id = rs.id
                WHERE cm.cluster_id = ? AND cm.membership >= ?
                """

            var args: [DatabaseValueConvertible] = [clusterId, minMembership]
            if let sourceFilter, !sourceFilter.isEmpty {
                sql += " AND rs.title LIKE '%' || ? || '%'"
                args.append(sourceFilter)
            }
            sql += " GROUP BY cm.event_id ORDER BY cm.membership DESC LIMIT ?"
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            var output = "## Provenance for \(label ?? "Theme \(clusterId)") (size \(size))\n"
            if let summary, !summary.isEmpty { output += "_\(summary)_\n" }
            output += "\nShowing \(rows.count) member event(s) (limit \(limit), min membership \(minMembership)).\n\n"

            for row in rows {
                let eventId: Int64 = row["event_id"]
                let membership: Double? = row["membership"]
                let edgeLabel: String = row["edge_label"]
                let sources: String? = row["sources"]
                let targets: String? = row["targets"]
                let articleTitle: String? = row["article_title"]
                let articleLink: String? = row["article_link"]
                let sourceName: String? = row["source_name"]
                let chunkIndex: Int? = row["chunk_index"]
                let chunkText: String? = row["chunk_text"]

                let memText = membership.map { "membership=\($0.formatted(.number.precision(.fractionLength(2))))" } ?? "membership=?"
                output += "### Event #\(eventId) — \(memText)\n"
                let targetList = targets ?? ""
                if targetList.isEmpty {
                    output += "- \(sources ?? "?") **\(edgeLabel)**\n"
                } else {
                    output += "- \(sources ?? "?") **\(edgeLabel)** \(targetList)\n"
                }
                if let articleTitle {
                    output += "- Article: \(articleTitle)"
                    if let sourceName { output += " (\(sourceName))" }
                    if let articleLink { output += " — \(articleLink)" }
                    output += "\n"
                }
                if includeChunkText, let chunkText, !chunkText.isEmpty {
                    let trimmed = chunkText.count > 500 ? chunkText.prefix(500) + "…" : Substring(chunkText)
                    output += "- Chunk \(chunkIndex.map(String.init) ?? "?"): \(trimmed)\n"
                }
                output += "\n"
            }
            return output
        }
    }
}
