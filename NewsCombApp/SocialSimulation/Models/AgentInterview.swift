import Foundation
import GRDB

/// A persisted interview conversation with a social agent.
struct AgentInterview: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var agentId: Int64
    var messagesJson: String
    var simulationId: String
    var createdAt: Date

    static let databaseTableName = "agent_interview"

    enum CodingKeys: String, CodingKey {
        case id
        case agentId = "agent_id"
        case messagesJson = "messages_json"
        case simulationId = "simulation_id"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id
        case agentId = "agent_id"
        case messagesJson = "messages_json"
        case simulationId = "simulation_id"
        case createdAt = "created_at"
    }

    init(
        id: Int64? = nil,
        agentId: Int64,
        messagesJson: String = "[]",
        simulationId: String,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.agentId = agentId
        self.messagesJson = messagesJson
        self.simulationId = simulationId
        self.createdAt = createdAt
    }

    /// A single message in an interview conversation.
    struct Message: Codable, Sendable, Equatable {
        var role: String
        var content: String
        var timestamp: Date
    }

    /// Decoded messages.
    var messages: [Message] {
        guard let data = messagesJson.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([Message].self, from: data)) ?? []
    }
}
