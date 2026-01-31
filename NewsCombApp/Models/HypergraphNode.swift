import Foundation
import GRDB

/// Represents a node (concept/entity) in the knowledge hypergraph.
struct HypergraphNode: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var nodeId: String
    var label: String
    var nodeType: String?
    var firstSeenAt: Date
    var metadataJson: String?
    /// Document frequency: number of events this node appears in.
    var df: Int?
    /// Inverse document frequency weight for TF-IDF based clustering.
    var idf: Double?

    static let databaseTableName = "hypergraph_node"

    enum CodingKeys: String, CodingKey {
        case id, label, df, idf
        case nodeId = "node_id"
        case nodeType = "node_type"
        case firstSeenAt = "first_seen_at"
        case metadataJson = "metadata_json"
    }

    enum Columns: String, ColumnExpression {
        case id
        case nodeId = "node_id"
        case label
        case nodeType = "node_type"
        case firstSeenAt = "first_seen_at"
        case metadataJson = "metadata_json"
        case df
        case idf
    }

    init(
        id: Int64? = nil,
        nodeId: String,
        label: String,
        nodeType: String? = nil,
        firstSeenAt: Date = Date(),
        metadataJson: String? = nil,
        df: Int? = nil,
        idf: Double? = nil
    ) {
        self.id = id
        self.nodeId = nodeId
        self.label = label
        self.nodeType = nodeType
        self.firstSeenAt = firstSeenAt
        self.metadataJson = metadataJson
        self.df = df
        self.idf = idf
    }
}
