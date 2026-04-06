import Foundation
import GRDB
import MCP

/// Lists recently ingested articles from RSS feeds.
enum MCPGetRecentArticlesTool {
    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()
    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.shared) throws -> String {
        let limit = arguments["limit"]?.intValue ?? 20
        let sourceFilter = arguments["source"]?.stringValue

        let results = try database.read { db -> [Row] in
            if let sourceFilter, !sourceFilter.isEmpty {
                return try Row.fetchAll(db, sql: """
                    SELECT fi.id, fi.title, fi.link, fi.pub_date,
                           rs.title AS source_title,
                           CASE WHEN ah.processing_status = 'completed' THEN 1 ELSE 0 END AS is_processed
                    FROM feed_item fi
                    LEFT JOIN rss_source rs ON fi.source_id = rs.id
                    LEFT JOIN article_hypergraph ah ON fi.id = ah.feed_item_id
                    WHERE rs.title LIKE '%' || ? || '%'
                    ORDER BY fi.pub_date DESC
                    LIMIT ?
                """, arguments: [sourceFilter, limit])
            } else {
                return try Row.fetchAll(db, sql: """
                    SELECT fi.id, fi.title, fi.link, fi.pub_date,
                           rs.title AS source_title,
                           CASE WHEN ah.processing_status = 'completed' THEN 1 ELSE 0 END AS is_processed
                    FROM feed_item fi
                    LEFT JOIN rss_source rs ON fi.source_id = rs.id
                    LEFT JOIN article_hypergraph ah ON fi.id = ah.feed_item_id
                    ORDER BY fi.pub_date DESC
                    LIMIT ?
                """, arguments: [limit])
            }
        }

        guard !results.isEmpty else {
            if let sourceFilter {
                return "No articles found from source matching '\(sourceFilter)'."
            }
            return "No articles found. Articles are ingested by the NewsComb app's RSS feed refresh."
        }

        var output: String
        if let sourceFilter {
            output = "Recent articles from '\(sourceFilter)' (\(results.count)):\n\n"
        } else {
            output = "Recent \(results.count) article(s):\n\n"
        }

        for row in results {
            let title: String = row["title"]
            let link: String? = row["link"]
            let pubDate: Double? = row["pub_date"]
            let sourceTitle: String? = row["source_title"]
            let isProcessed: Int = row["is_processed"]

            output += "- **\(title)**"
            if let sourceTitle { output += " (\(sourceTitle))" }
            if let pubDate {
                let date = Date(timeIntervalSince1970: pubDate)
                output += " — \(Self.dateFormatter.string(from: date))"
            }
            if isProcessed == 1 { output += " [processed]" }
            if let link { output += "\n  \(link)" }
            output += "\n"
        }
        return output
    }
}
