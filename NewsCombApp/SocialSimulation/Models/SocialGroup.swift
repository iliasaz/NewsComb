import Foundation
import GRDB

/// A group created during a social simulation.
struct SocialGroup: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var oasisGroupId: Int?
    var name: String
    var creatorAgentId: Int64
    var roundNum: Int
    var simulationId: String

    static let databaseTableName = "social_group"

    enum CodingKeys: String, CodingKey {
        case id
        case oasisGroupId = "oasis_group_id"
        case name
        case creatorAgentId = "creator_agent_id"
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }

    enum Columns: String, ColumnExpression {
        case id
        case oasisGroupId = "oasis_group_id"
        case name
        case creatorAgentId = "creator_agent_id"
        case roundNum = "round_num"
        case simulationId = "simulation_id"
    }
}
