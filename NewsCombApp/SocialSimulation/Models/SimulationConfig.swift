import Foundation

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
}
