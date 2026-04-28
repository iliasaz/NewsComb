import Foundation
import GRDB

/// Configuration for a social simulation run, stored as JSON in `social_simulation.config_json`.
struct SimulationConfig: Codable, Sendable, Equatable {
    var maxRounds: Int
    var minutesPerRound: Double
    var platforms: [String]
    var agentsPerHourMin: Int
    var agentsPerHourMax: Int
    var pythonPath: String
    var llmApiKey: String?
    var llmBaseUrl: String?
    var llmModelName: String?
    var semaphoreLimit: Int

    init(
        maxRounds: Int = 72,
        minutesPerRound: Double = 60.0,
        platforms: [String] = ["twitter"],
        agentsPerHourMin: Int = 3,
        agentsPerHourMax: Int = 10,
        pythonPath: String = "/usr/bin/python3",
        llmApiKey: String? = nil,
        llmBaseUrl: String? = nil,
        llmModelName: String? = nil,
        semaphoreLimit: Int = 128
    ) {
        self.maxRounds = maxRounds
        self.minutesPerRound = minutesPerRound
        self.platforms = platforms
        self.agentsPerHourMin = agentsPerHourMin
        self.agentsPerHourMax = agentsPerHourMax
        self.pythonPath = pythonPath
        self.llmApiKey = llmApiKey
        self.llmBaseUrl = llmBaseUrl
        self.llmModelName = llmModelName
        self.semaphoreLimit = semaphoreLimit
    }

    /// Loads persisted simulation parameters from the database.
    ///
    /// All reads happen inside the GRDB read closure to avoid thread safety violations.
    static func loadPersistedDefaults() -> (agentsPerHourMin: Int, agentsPerHourMax: Int, semaphoreLimit: Int) {
        var agentsMin = AppSettings.defaultSimAgentsPerHourMin
        var agentsMax = AppSettings.defaultSimAgentsPerHourMax
        var semaphore = AppSettings.defaultSimSemaphoreLimit

        do {
            try Database.current.read { db in
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simAgentsPerHourMin).fetchOne(db),
                   let v = Int(s.value) { agentsMin = v }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simAgentsPerHourMax).fetchOne(db),
                   let v = Int(s.value) { agentsMax = v }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simSemaphoreLimit).fetchOne(db),
                   let v = Int(s.value) { semaphore = v }
            }
        } catch {
            // Use defaults on error
        }

        return (agentsMin, agentsMax, semaphore)
    }
}
