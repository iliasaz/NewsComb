import Foundation
import GRDB

/// A social agent persona derived from a hypergraph node.
///
/// The `nodeId` is a read-only reference back to the source entity in the knowledge
/// hypergraph. The agent is a snapshot — it persists independently even if the
/// source node changes.
struct SocialAgent: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var nodeId: Int64
    var displayName: String
    var bio: String
    var personaJson: String?
    var simulationId: String
    var oasisUserId: Int?
    var createdAt: Date

    static let databaseTableName = "social_agent"

    enum CodingKeys: String, CodingKey {
        case id
        case nodeId = "node_id"
        case displayName = "display_name"
        case bio
        case personaJson = "persona_json"
        case simulationId = "simulation_id"
        case oasisUserId = "oasis_user_id"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id
        case nodeId = "node_id"
        case displayName = "display_name"
        case bio
        case personaJson = "persona_json"
        case simulationId = "simulation_id"
        case oasisUserId = "oasis_user_id"
        case createdAt = "created_at"
    }

    init(
        id: Int64? = nil,
        nodeId: Int64,
        displayName: String,
        bio: String,
        personaJson: String? = nil,
        simulationId: String,
        oasisUserId: Int? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.nodeId = nodeId
        self.displayName = displayName
        self.bio = bio
        self.personaJson = personaJson
        self.simulationId = simulationId
        self.oasisUserId = oasisUserId
        self.createdAt = createdAt
    }

    /// Decoded persona attributes.
    var persona: AgentPersona? {
        guard let json = personaJson,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(AgentPersona.self, from: data)
    }
}
