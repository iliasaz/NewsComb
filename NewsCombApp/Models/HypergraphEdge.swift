import Foundation
import GRDB

/// Represents a hyperedge (relationship) in the knowledge hypergraph.
struct HypergraphEdge: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var edgeId: String
    var label: String
    var createdAt: Date
    var metadataJson: String?

    static let databaseTableName = "hypergraph_edge"

    enum CodingKeys: String, CodingKey {
        case id, label
        case edgeId = "edge_id"
        case createdAt = "created_at"
        case metadataJson = "metadata_json"
    }

    enum Columns: String, ColumnExpression {
        case id
        case edgeId = "edge_id"
        case label
        case createdAt = "created_at"
        case metadataJson = "metadata_json"
    }

    init(
        id: Int64? = nil,
        edgeId: String,
        label: String,
        createdAt: Date = Date(),
        metadataJson: String? = nil
    ) {
        self.id = id
        self.edgeId = edgeId
        self.label = label
        self.createdAt = createdAt
        self.metadataJson = metadataJson
    }
}
