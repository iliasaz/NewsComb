import Foundation
import GRDB

/// A directed follow relationship between two social agents.
///
/// The `source` field distinguishes how the connection was established:
/// - `"initial"`: derived from hypergraph co-occurrence or embedding similarity
/// - `"simulation"`: created by an agent's follow action during simulation
struct SocialConnection: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var followerId: Int64
    var followeeId: Int64
    var source: String
    var roundNum: Int?
    var simulationId: String

    static let databaseTableName = "social_connection"

    enum CodingKeys: String, CodingKey {
        case id
        case followerId = "follower_id"
        case followeeId = "followee_id"
        case source
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }

    enum Columns: String, ColumnExpression {
        case id
        case followerId = "follower_id"
        case followeeId = "followee_id"
        case source
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }

    init(
        id: Int64? = nil,
        followerId: Int64,
        followeeId: Int64,
        source: String = "initial",
        roundNum: Int? = nil,
        simulationId: String
    ) {
        self.id = id
        self.followerId = followerId
        self.followeeId = followeeId
        self.source = source
        self.roundNum = roundNum
        self.simulationId = simulationId
    }
}
