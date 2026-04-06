import Foundation
import GRDB
import MCP

/// Returns knowledge graph statistics.
enum GetStatisticsTool {
    static func run(arguments: [String: Value], database: ReadOnlyDatabase) throws -> String {
        try database.read { db in
            let nodeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node") ?? 0
            let edgeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_edge") ?? 0
            let processedArticles = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM article_hypergraph WHERE processing_status = 'completed'
            """) ?? 0
            let totalArticles = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item") ?? 0
            let chunkCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_chunk") ?? 0
            let embeddingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node_embedding_metadata") ?? 0
            let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source") ?? 0
            let clusterCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clusters") ?? 0
            let queryCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM query_history") ?? 0

            // Type distribution
            let typeRows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(node_type, 'unclassified') AS type, COUNT(*) AS count
                FROM hypergraph_node
                GROUP BY node_type
                ORDER BY count DESC
                LIMIT 10
            """)

            var output = """
                ## NewsComb Knowledge Graph Statistics

                | Metric | Count |
                |--------|-------|
                | RSS Sources | \(sourceCount) |
                | Total Articles | \(totalArticles) |
                | Processed Articles | \(processedArticles) |
                | Article Chunks | \(chunkCount) |
                | Graph Nodes (Entities) | \(nodeCount) |
                | Graph Edges (Relationships) | \(edgeCount) |
                | Node Embeddings | \(embeddingCount) |
                | Story Theme Clusters | \(clusterCount) |
                | Saved Queries | \(queryCount) |

                """

            if !typeRows.isEmpty {
                output += "\n### Entity Type Distribution\n"
                for row in typeRows {
                    let type: String = row["type"]
                    let count: Int = row["count"]
                    output += "- \(type): \(count)\n"
                }
            }

            return output
        }
    }
}
