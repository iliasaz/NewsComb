import Foundation
import GRDB
import Observation
import OSLog

/// View model for the simulation dashboard — monitors a running simulation
/// and displays its results.
@MainActor
@Observable
final class SimulationDashboardViewModel {

    // MARK: - State

    private(set) var simulation: SocialSimulation
    private(set) var status: SimulationStatus = .idle
    private(set) var stats: SocialGraphService.SimulationStats?
    private(set) var agents: [SocialAgent] = []
    private(set) var recentPosts: [SocialPost] = []

    private(set) var isGeneratingProfiles = false
    private(set) var profileProgress: Double = 0
    private(set) var statusMessage: String = ""
    var errorMessage: String?

    // MARK: - Internal

    private let engine = SimulationEngine()
    private let profileService = AgentProfileService()
    private let exportService = OasisExportService()
    private let graphService = SocialGraphService()
    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "SimulationDashboardViewModel")

    private var statusTask: Task<Void, Never>? {
        willSet { statusTask?.cancel() }
    }

    init(simulation: SocialSimulation) {
        self.simulation = simulation
    }

    // MARK: - Data Loading

    func loadData() {
        do {
            agents = try graphService.agents(for: simulation.id)
            stats = try graphService.stats(simulationId: simulation.id)
            recentPosts = try graphService.posts(simulationId: simulation.id, limit: 50)

            // Refresh simulation record
            if let updated = try database.read({ db in
                try SocialSimulation.fetchOne(db, key: simulation.id)
            }) {
                simulation = updated
            }
        } catch {
            logger.error("Failed to load data: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Profile Generation

    /// Generates agent profiles from selected hypergraph nodes.
    func generateProfiles(nodeIds: [Int64] = [], maxAgents: Int = 30) async {
        isGeneratingProfiles = true
        profileProgress = 0
        statusMessage = "Starting profile generation\u{2026}"

        do {
            let generatedAgents = try await profileService.generateProfiles(
                simulationId: simulation.id,
                nodeIds: nodeIds,
                maxAgents: maxAgents,
                statusCallback: { [weak self] message in
                    self?.statusMessage = message
                },
                progressCallback: { [weak self] progress in
                    self?.profileProgress = progress
                }
            )

            agents = generatedAgents
            statusMessage = "Generated \(generatedAgents.count) agent profiles"
            loadData()
        } catch {
            logger.error("Profile generation failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }

        isGeneratingProfiles = false
    }

    // MARK: - Simulation Control

    /// Exports profiles and launches the OASIS simulation.
    func startSimulation(config: SimulationConfig) async {
        statusMessage = "Exporting to OASIS\u{2026}"

        do {
            // Save config
            let configData = try JSONEncoder().encode(config)
            let configJson = String(data: configData, encoding: .utf8)
            try database.write { db in
                try db.execute(
                    sql: "UPDATE social_simulation SET config_json = ?, max_rounds = ? WHERE id = ?",
                    arguments: [configJson, config.maxRounds, simulation.id]
                )
            }

            // Export
            let simDir = try await exportService.exportSimulation(
                simulationId: simulation.id,
                config: config
            )

            // Subscribe to status updates
            subscribeToStatus()

            // Launch
            try await engine.startSimulation(
                simulationId: simulation.id,
                config: config,
                simDirectory: simDir
            )

            statusMessage = "Simulation running"
        } catch {
            logger.error("Failed to start simulation: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    /// Stops the running simulation.
    func stopSimulation() async {
        do {
            try await engine.stopSimulation(simulationId: simulation.id)
            loadData()
        } catch {
            logger.error("Failed to stop simulation: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Status Subscription

    private func subscribeToStatus() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.makeStatusStream()
            for await newStatus in stream {
                self.status = newStatus
                self.statusMessage = newStatus.displayText

                // Periodically refresh data during simulation
                if case .running(let round, _) = newStatus, round % 5 == 0 {
                    self.loadData()
                }

                // Final refresh when complete
                if case .completed = newStatus {
                    self.loadData()
                }
                if case .waitingForInterviews = newStatus {
                    self.loadData()
                }
            }
        }
    }

    // MARK: - Computed

    var isRunning: Bool {
        status.isActive
    }

    var hasAgents: Bool {
        !agents.isEmpty
    }

    var hasPosts: Bool {
        !recentPosts.isEmpty
    }
}
