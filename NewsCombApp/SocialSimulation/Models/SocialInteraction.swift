import Foundation
import GRDB

/// An interaction between a social agent and a post during simulation (like, repost, bookmark).
struct SocialInteraction: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var agentId: Int64
    var postId: Int64?
    var actionType: String
    var simTimestamp: Double
    var roundNum: Int
    var simulationId: String

    static let databaseTableName = "social_interaction"

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case postId = "post_id"
        case actionType = "action_type"
        case simTimestamp = "sim_timestamp"
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }

    enum Columns: String, ColumnExpression {
        case id
        case agentId = "agent_id"
        case postId = "post_id"
        case actionType = "action_type"
        case simTimestamp = "sim_timestamp"
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }
}
