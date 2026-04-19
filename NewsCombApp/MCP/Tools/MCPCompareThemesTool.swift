import Foundation
import GRDB
import MCP

/// Compares two or more themes along several axes:
///  - Centroid cosine similarity (semantic closeness)
///  - Top-entity Jaccard overlap (do they discuss the same actors?)
///  - Shared articles (do they describe the same source material?)
///
/// Useful for spotting near-duplicate clusters, related sub-themes, or unexpectedly
/// connected topics that the labeling LLM may have missed.
enum MCPCompareThemesTool {
    static func run(arguments: [String: Value], database: any MCPDatabaseReader = Database.shared) throws -> String {
        guard let idsValue = arguments["cluster_ids"] else {
            throw MCPToolError.missingParameter("cluster_ids")
        }
        let clusterIds = idsValue.arrayValue?.compactMap { $0.intValue } ?? []
        guard clusterIds.count >= 2 else {
            throw MCPToolError.invalidParameter("cluster_ids", detail: "Provide at least 2 cluster IDs.")
        }

        return try database.read { db -> String in
            // Load metadata + centroid blob for each requested cluster.
            var metas: [(id: Int, label: String?, size: Int, centroid: [Float], topEntities: Set<String>)] = []
            for cid in clusterIds {
                guard let row = try Row.fetchOne(db, sql: """
                    SELECT cluster_id, label, size, centroid_vec, top_entities_json
                    FROM clusters WHERE cluster_id = ?
                """, arguments: [cid]) else {
                    throw MCPToolError.notFound("Theme cluster \(cid) not found.")
                }
                let label: String? = row["label"]
                let size: Int = row["size"]
                let blob: Data? = row["centroid_vec"]
                let centroid = blob.map { decodeFloatVector($0) } ?? []
                let topEntities = decodeTopEntityLabels(row["top_entities_json"])
                metas.append((cid, label, size, centroid, topEntities))
            }

            // Article membership per cluster, for shared-article comparison.
            var articleSets: [Int: Set<Int64>] = [:]
            for cid in clusterIds {
                let ids = try Int64.fetchAll(db, sql: """
                    SELECT DISTINCT aep.feed_item_id
                    FROM cluster_members cm
                    JOIN article_edge_provenance aep ON cm.event_id = aep.edge_id
                    WHERE cm.cluster_id = ?
                """, arguments: [cid])
                articleSets[cid] = Set(ids)
            }

            var output = "## Theme Comparison\n\n"
            for m in metas {
                output += "- **\(m.label ?? "Theme \(m.id)")** (cluster_id=\(m.id), size=\(m.size))\n"
            }
            output += "\n"

            output += "### Pairwise Similarity\n\n"
            output += "| A | B | Centroid cos | Top-entity Jaccard | Shared articles |\n"
            output += "|---|---|--------------|--------------------|------------------|\n"
            for i in 0 ..< metas.count {
                for j in (i + 1) ..< metas.count {
                    let a = metas[i]
                    let b = metas[j]
                    let cosine = (a.centroid.isEmpty || b.centroid.isEmpty) ? Double.nan : cosineSimilarity(a.centroid, b.centroid)
                    let jaccard = jaccardSimilarity(a.topEntities, b.topEntities)
                    let sharedArticles = (articleSets[a.id] ?? []).intersection(articleSets[b.id] ?? []).count
                    let cosText = cosine.isNaN ? "n/a" : cosine.formatted(.number.precision(.fractionLength(3)))
                    let jacText = jaccard.formatted(.number.precision(.fractionLength(3)))
                    output += "| \(a.label ?? "T\(a.id)") | \(b.label ?? "T\(b.id)") | \(cosText) | \(jacText) | \(sharedArticles) |\n"
                }
            }

            // Articles appearing in *all* requested clusters — the strongest signal of overlap.
            let intersection = articleSets.values.reduce(into: Set<Int64>()) { acc, set in
                acc = acc.isEmpty ? set : acc.intersection(set)
            }
            if !intersection.isEmpty {
                let titles = try Row.fetchAll(db, sql: """
                    SELECT title, link FROM feed_item WHERE id IN (\(intersection.map { String($0) }.joined(separator: ",")))
                    LIMIT 20
                """)
                output += "\n### Articles common to all \(metas.count) themes (\(intersection.count) total)\n"
                for row in titles {
                    let title: String = row["title"]
                    let link: String? = row["link"]
                    output += "- \(title)"
                    if let link { output += " — \(link)" }
                    output += "\n"
                }
            }
            return output
        }
    }

    // MARK: - Helpers

    private static func decodeFloatVector(_ data: Data) -> [Float] {
        let count = data.count / MemoryLayout<Float>.size
        return data.withUnsafeBytes { raw -> [Float] in
            let buf = raw.bindMemory(to: Float.self)
            return Array(UnsafeBufferPointer(start: buf.baseAddress, count: count))
        }
    }

    private static func decodeTopEntityLabels(_ json: String?) -> Set<String> {
        guard let json, let data = json.data(using: .utf8),
              let entities = try? JSONDecoder().decode([MCPRankedEntity].self, from: data)
        else { return [] }
        return Set(entities.map { $0.label.lowercased() })
    }

    private static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Double {
        let n = min(a.count, b.count)
        guard n > 0 else { return .nan }
        var dot: Double = 0
        var na: Double = 0
        var nb: Double = 0
        for i in 0 ..< n {
            let ai = Double(a[i])
            let bi = Double(b[i])
            dot += ai * bi
            na += ai * ai
            nb += bi * bi
        }
        let denom = (na.squareRoot()) * (nb.squareRoot())
        return denom == 0 ? .nan : dot / denom
    }

    private static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        guard union > 0 else { return 0 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
