import Foundation
import GRDB

/// Maps a hyperedge (event) to its cluster assignment for a given build.
struct EventCluster: Codable, FetchableRecord, PersistableRecord {
    var eventId: Int64
    var buildId: String
    var clusterId: Int64
    var membership: Double

    static let databaseTableName = "event_cluster"

    enum CodingKeys: String, CodingKey {
        case eventId = "event_id"
        case buildId = "build_id"
        case clusterId = "cluster_id"
        case membership
    }

    enum Columns: String, ColumnExpression {
        case eventId = "event_id"
        case buildId = "build_id"
        case clusterId = "cluster_id"
        case membership
    }
}

/// A cluster member entry linking a cluster to one of its constituent events.
struct ClusterMember: Codable, FetchableRecord, PersistableRecord {
    var clusterId: Int64
    var eventId: Int64
    var membership: Double

    static let databaseTableName = "cluster_members"

    enum CodingKeys: String, CodingKey {
        case clusterId = "cluster_id"
        case eventId = "event_id"
        case membership
    }

    enum Columns: String, ColumnExpression {
        case clusterId = "cluster_id"
        case eventId = "event_id"
        case membership
    }
}

/// An exemplar event for a cluster, ranked by proximity to the cluster centroid.
struct ClusterExemplar: Codable, FetchableRecord, PersistableRecord {
    var clusterId: Int64
    var eventId: Int64
    var rank: Int

    static let databaseTableName = "cluster_exemplars"

    enum CodingKeys: String, CodingKey {
        case clusterId = "cluster_id"
        case eventId = "event_id"
        case rank
    }

    enum Columns: String, ColumnExpression {
        case clusterId = "cluster_id"
        case eventId = "event_id"
        case rank
    }
}
