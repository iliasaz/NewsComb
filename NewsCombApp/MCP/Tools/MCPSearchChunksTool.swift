import Foundation
import GRDB
import MCP

/// Searches article text chunks using FTS5.
enum MCPSearchChunksTool {
    static func run(arguments: [String: Value]) throws -> String {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw MCPToolError.missingParameter("query")
        }
        let limit = arguments["limit"]?.intValue ?? 10

        let results = try Database.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT ac.id, ac.chunk_index, ac.content,
                       fi.title AS article_title, fi.link AS article_link,
                       rs.title AS source_title, rank
                FROM fts_chunk
                JOIN article_chunk ac ON fts_chunk.rowid = ac.id
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                LEFT JOIN rss_source rs ON fi.source_id = rs.id
                WHERE fts_chunk MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [query, limit])
        }

        guard !results.isEmpty else {
            return "No article content found matching '\(query)'."
        }

        var output = "Found \(results.count) matching chunk(s):\n\n"
        for (index, row) in results.enumerated() {
            let articleTitle: String = row["article_title"]
            let content: String = row["content"]
            let link: String? = row["article_link"]
            let sourceTitle: String? = row["source_title"]

            output += "### \(index + 1). \(articleTitle)\n"
            if let sourceTitle { output += "Source: \(sourceTitle)\n" }
            if let link { output += "Link: \(link)\n" }
            let truncated = content.count > 500 ? String(content.prefix(500)) + "..." : content
            output += "\n\(truncated)\n\n"
        }
        return output
    }
}
