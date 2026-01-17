import Foundation
import GRDB

/// Represents the incidence relationship between edges and nodes.
/// This junction table connects hyperedges to their constituent nodes.
struct HypergraphIncidence: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var edgeId: Int64
    var nodeId: Int64
    var role: String
    var position: Int

    static let databaseTableName = "hypergraph_incidence"

    enum CodingKeys: String, CodingKey {
        case id, role, position
        case edgeId = "edge_id"
        case nodeId = "node_id"
    }

    enum Columns: String, ColumnExpression {
        case id
        case edgeId = "edge_id"
        case nodeId = "node_id"
        case role
        case position
    }

    init(
        id: Int64? = nil,
        edgeId: Int64,
        nodeId: Int64,
        role: String,
        position: Int = 0
    ) {
        self.id = id
        self.edgeId = edgeId
        self.nodeId = nodeId
        self.role = role
        self.position = position
    }
}

// MARK: - Role Constants

extension HypergraphIncidence {
    static let roleSource = "source"
    static let roleTarget = "target"
}
