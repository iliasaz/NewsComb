import Foundation
import GRDB

/// A cluster of related hyperedges representing a coherent story theme.
struct StoryCluster: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    var clusterId: Int64
    var buildId: String
    var label: String?
    var size: Int
    var centroidVec: Data?
    var topEntitiesJson: String?
    var topRelFamiliesJson: String?
    var summary: String?
    var createdAt: Date
    var parentClusterId: Int64?
    var isTentative: Bool

    var id: Int64 { clusterId }

    static func == (lhs: StoryCluster, rhs: StoryCluster) -> Bool {
        lhs.clusterId == rhs.clusterId
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(clusterId)
    }

    static let databaseTableName = "clusters"

    enum CodingKeys: String, CodingKey {
        case clusterId = "cluster_id"
        case buildId = "build_id"
        case label, size
        case centroidVec = "centroid_vec"
        case topEntitiesJson = "top_entities_json"
        case topRelFamiliesJson = "top_rel_families_json"
        case summary
        case createdAt = "created_at"
        case parentClusterId = "parent_cluster_id"
        case isTentative = "is_tentative"
    }

    enum Columns: String, ColumnExpression {
        case clusterId = "cluster_id"
        case buildId = "build_id"
        case label, size
        case centroidVec = "centroid_vec"
        case topEntitiesJson = "top_entities_json"
        case topRelFamiliesJson = "top_rel_families_json"
        case summary
        case createdAt = "created_at"
        case parentClusterId = "parent_cluster_id"
        case isTentative = "is_tentative"
    }

    init(
        clusterId: Int64,
        buildId: String,
        label: String? = nil,
        size: Int,
        centroidVec: Data? = nil,
        topEntitiesJson: String? = nil,
        topRelFamiliesJson: String? = nil,
        summary: String? = nil,
        createdAt: Date,
        parentClusterId: Int64? = nil,
        isTentative: Bool = false
    ) {
        self.clusterId = clusterId
        self.buildId = buildId
        self.label = label
        self.size = size
        self.centroidVec = centroidVec
        self.topEntitiesJson = topEntitiesJson
        self.topRelFamiliesJson = topRelFamiliesJson
        self.summary = summary
        self.createdAt = createdAt
        self.parentClusterId = parentClusterId
        self.isTentative = isTentative
    }

    /// Decoded top entities with their IDF-weighted scores.
    var topEntities: [RankedEntity] {
        guard let json = topEntitiesJson,
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RankedEntity].self, from: data)) ?? []
    }

    /// Decoded top relation families.
    var topRelFamilies: [RankedFamily] {
        guard let json = topRelFamiliesJson,
              let data = json.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([RankedFamily].self, from: data)) ?? []
    }
}

/// An entity ranked by weighted frequency within a cluster.
struct RankedEntity: Codable, Equatable, Identifiable {
    let label: String
    let score: Double

    var id: String { label }
}

/// A relation family ranked by frequency within a cluster.
struct RankedFamily: Codable, Equatable, Identifiable {
    let family: String
    let count: Int

    var id: String { family }
}
