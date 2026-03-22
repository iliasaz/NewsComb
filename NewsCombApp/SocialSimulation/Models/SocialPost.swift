import Foundation
import GRDB

/// A post created by a social agent during simulation, ingested from OASIS action logs.
struct SocialPost: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var agentId: Int64
    var content: String
    var parentPostId: Int64?
    var repostOfId: Int64?
    var simTimestamp: Double
    var roundNum: Int
    var platform: String
    var oasisPostId: Int?
    var simulationId: String
    var createdAt: Date

    static let databaseTableName = "social_post"

    enum CodingKeys: String, CodingKey {
        case id, content, platform
        case agentId = "agent_id"
        case parentPostId = "parent_post_id"
        case repostOfId = "repost_of_id"
        case simTimestamp = "sim_timestamp"
        case roundNum = "round_num"
        case oasisPostId = "oasis_post_id"
        case simulationId = "simulation_id"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id, content, platform
        case agentId = "agent_id"
        case parentPostId = "parent_post_id"
        case repostOfId = "repost_of_id"
        case simTimestamp = "sim_timestamp"
        case roundNum = "round_num"
        case oasisPostId = "oasis_post_id"
        case simulationId = "simulation_id"
        case createdAt = "created_at"
    }

    init(
        id: Int64? = nil,
        agentId: Int64,
        content: String,
        parentPostId: Int64? = nil,
        repostOfId: Int64? = nil,
        simTimestamp: Double,
        roundNum: Int,
        platform: String = "twitter",
        oasisPostId: Int? = nil,
        simulationId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.agentId = agentId
        self.content = content
        self.parentPostId = parentPostId
        self.repostOfId = repostOfId
        self.simTimestamp = simTimestamp
        self.roundNum = roundNum
        self.platform = platform
        self.oasisPostId = oasisPostId
        self.simulationId = simulationId
        self.createdAt = createdAt
    }
}
