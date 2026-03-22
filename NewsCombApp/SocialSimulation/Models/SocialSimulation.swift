import Foundation
import GRDB

/// Metadata for a social simulation run.
struct SocialSimulation: Identifiable, Hashable, Codable, FetchableRecord, PersistableRecord {
    var id: String
    var name: String
    var status: String
    var agentCount: Int
    var roundCount: Int
    var maxRounds: Int
    var simDirectory: String?
    var configJson: String?
    var startedAt: Date?
    var completedAt: Date?
    var createdAt: Date

    static let databaseTableName = "social_simulation"

    enum CodingKeys: String, CodingKey {
        case id, name, status
        case agentCount = "agent_count"
        case roundCount = "round_count"
        case maxRounds = "max_rounds"
        case simDirectory = "sim_directory"
        case configJson = "config_json"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id, name, status
        case agentCount = "agent_count"
        case roundCount = "round_count"
        case maxRounds = "max_rounds"
        case simDirectory = "sim_directory"
        case configJson = "config_json"
        case startedAt = "started_at"
        case completedAt = "completed_at"
        case createdAt = "created_at"
    }

    init(
        id: String = UUID().uuidString,
        name: String,
        status: String = "configuring",
        agentCount: Int = 0,
        roundCount: Int = 0,
        maxRounds: Int = 72,
        simDirectory: String? = nil,
        configJson: String? = nil,
        startedAt: Date? = nil,
        completedAt: Date? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.status = status
        self.agentCount = agentCount
        self.roundCount = roundCount
        self.maxRounds = maxRounds
        self.simDirectory = simDirectory
        self.configJson = configJson
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.createdAt = createdAt
    }

    /// Decoded simulation configuration.
    var config: SimulationConfig? {
        guard let json = configJson,
              let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(SimulationConfig.self, from: data)
    }
}
