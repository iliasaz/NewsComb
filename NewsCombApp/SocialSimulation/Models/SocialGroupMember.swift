import Foundation
import GRDB

/// An agent's membership in a social group.
struct SocialGroupMember: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var groupId: Int64
    var agentId: Int64
    var roundNum: Int
    var simulationId: String

    static let databaseTableName = "social_group_member"

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case agentId = "agent_id"
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }

    enum Columns: String, ColumnExpression {
        case id
        case groupId = "group_id"
        case agentId = "agent_id"
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }
}
