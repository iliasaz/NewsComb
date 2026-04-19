import Foundation
import GRDB
import MCP

/// Finds articles whose extracted relationships span multiple theme clusters.
/// Surfaces articles that bridge separate stories — useful for editorial analysis,
/// trend correlation, and finding "hub" articles that touch many narratives.
enum MCPFindArticlesAcrossThemesTool {
    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.shared) throws -> String {
        let minThemes = arguments["min_themes"]?.intValue ?? 2
        let limit = arguments["limit"]?.intValue ?? 20

        return try database.read { db -> String in
            // For each article, count distinct cluster_ids reached via its edges' provenance.
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    fi.id AS article_id,
                    fi.title,
                    fi.link,
                    rs.title AS source_name,
                    COUNT(DISTINCT cm.cluster_id) AS theme_count,
                    GROUP_CONCAT(DISTINCT COALESCE(c.label, 'Theme ' || cm.cluster_id)) AS themes
                FROM feed_item fi
                JOIN article_edge_provenance aep ON aep.feed_item_id = fi.id
                JOIN cluster_members cm ON cm.event_id = aep.edge_id
                JOIN clusters c ON c.cluster_id = cm.cluster_id
                LEFT JOIN rss_source rs ON fi.source_id = rs.id
                GROUP BY fi.id
                HAVING theme_count >= ?
                ORDER BY theme_count DESC, fi.pub_date DESC
                LIMIT ?
            """, arguments: [minThemes, limit])

            guard !rows.isEmpty else {
                return "No articles span \(minThemes) or more themes. Try lowering min_themes or rebuilding themes first."
            }

            var output = "## Articles spanning \(minThemes)+ themes (\(rows.count) shown)\n\n"
            for row in rows {
                let title: String = row["title"]
                let link: String? = row["link"]
                let sourceName: String? = row["source_name"]
                let themeCount: Int = row["theme_count"]
                let themes: String? = row["themes"]

                output += "### \(title)"
                if let sourceName { output += " (\(sourceName))" }
                output += "\n"
                output += "- Spans **\(themeCount)** theme\(themeCount == 1 ? "" : "s")\n"
                if let themes { output += "- Themes: \(themes)\n" }
                if let link { output += "- \(link)\n" }
                output += "\n"
            }
            return output
        }
    }
}
