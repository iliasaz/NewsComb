import Foundation
import GRDB

/// A message sent to a social group during simulation.
struct SocialGroupMessage: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var groupId: Int64
    var agentId: Int64
    var content: String
    var roundNum: Int
    var simulationId: String

    static let databaseTableName = "social_group_message"

    enum CodingKeys: String, CodingKey {
        case id
        case groupId = "group_id"
        case agentId = "agent_id"
        case content
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }

    enum Columns: String, ColumnExpression {
        case id
        case groupId = "group_id"
        case agentId = "agent_id"
        case content
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }
}
