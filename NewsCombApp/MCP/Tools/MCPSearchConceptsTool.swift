import Foundation
import GRDB
import MCP

/// Searches for entities/concepts in the knowledge graph using FTS5.
enum MCPSearchConceptsTool {
    static func run(arguments: [String: Value]) throws -> String {
        guard let query = arguments["query"]?.stringValue, !query.isEmpty else {
            throw MCPToolError.missingParameter("query")
        }
        let limit = arguments["limit"]?.intValue ?? 20

        let results = try Database.shared.read { db in
            try Row.fetchAll(db, sql: """
                SELECT hn.id, hn.label, hn.node_type, hn.df, rank
                FROM fts_node
                JOIN hypergraph_node hn ON fts_node.rowid = hn.id
                WHERE fts_node MATCH ?
                ORDER BY rank
                LIMIT ?
            """, arguments: [query, limit])
        }

        guard !results.isEmpty else {
            return "No concepts found matching '\(query)'."
        }

        var output = "Found \(results.count) concept(s) matching '\(query)':\n\n"
        for row in results {
            let label: String = row["label"]
            let nodeType: String? = row["node_type"]
            let df: Int? = row["df"]

            output += "- **\(label)**"
            if let nodeType { output += " (\(nodeType))" }
            if let df, df > 0 { output += " — appears in \(df) events" }
            output += "\n"
        }
        return output
    }
}
