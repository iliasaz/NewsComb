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
    private(set) var actionBreakdown: [String: Int] = [:]

    private(set) var isGeneratingProfiles = false
    private(set) var profileProgress: Double = 0
    private(set) var statusMessage: String = ""
    var errorMessage: String?

    /// Activity log entries shown in the UI, newest first.
    private(set) var activityLog: [ActivityEntry] = []

    /// Environment check results.
    private(set) var pythonPath: String?
    private(set) var oasisStatus: OasisStatus?
    private(set) var isCheckingEnvironment = false
    private(set) var environmentChecked = false

    // MARK: - Internal

    private let engine = SimulationEngine()
    private let profileService = AgentProfileService()
    private let exportService = OasisExportService()
    private let graphService = SocialGraphService()
    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "SimDashboard")

    private var statusTask: Task<Void, Never>? {
        willSet { statusTask?.cancel() }
    }

    init(simulation: SocialSimulation) {
        self.simulation = simulation
        logger.info("Dashboard opened for simulation '\(simulation.name, privacy: .public)' [id=\(simulation.id.prefix(8), privacy: .public), status=\(simulation.status, privacy: .public)]")
    }

    // MARK: - Activity Log

    struct ActivityEntry: Identifiable {
        let id = UUID()
        let timestamp: Date
        let message: String
        let isError: Bool

        init(_ message: String, isError: Bool = false) {
            self.timestamp = Date()
            self.message = message
            self.isError = isError
        }
    }

    private func log(_ message: String) {
        logger.info("\(message, privacy: .public)")
        activityLog.insert(ActivityEntry(message), at: 0)
    }

    private func logError(_ message: String) {
        logger.error("\(message, privacy: .public)")
        activityLog.insert(ActivityEntry(message, isError: true), at: 0)
    }

    // MARK: - Data Loading

    func loadData() {
        log("Loading simulation data\u{2026}")
        do {
            agents = try graphService.agents(for: simulation.id)
            stats = try graphService.stats(simulationId: simulation.id)
            recentPosts = try graphService.posts(simulationId: simulation.id, limit: 50)
            actionBreakdown = try graphService.interactionSummary(simulationId: simulation.id)

            if let updated = try database.read({ db in
                try SocialSimulation.fetchOne(db, key: simulation.id)
            }) {
                simulation = updated
            }
            log("Loaded: \(agents.count) agents, \(stats?.postCount ?? 0) posts, \(stats?.connectionCount ?? 0) connections")
        } catch {
            logError("Failed to load data: \(error.localizedDescription)")
        }
    }

    // MARK: - Environment Check

    func checkEnvironment() async {
        isCheckingEnvironment = true
        log("Checking Python and OASIS environment\u{2026}")

        let envService = OasisEnvironmentService()
        pythonPath = await envService.detectPythonPath()

        if let python = pythonPath {
            log("Found Python at: \(python)")
            oasisStatus = await envService.checkOasisInstalled(pythonPath: python)
            switch oasisStatus! {
            case .installed(let version):
                log("OASIS v\(version) installed")
            case .notInstalled:
                logError("OASIS not installed. Run: pip install camel-oasis")
            case .pythonNotFound:
                logError("Python not found at expected path")
            case .error(let msg):
                logError("OASIS check error: \(msg)")
            }
        } else {
            oasisStatus = .pythonNotFound
            logError("No Python 3.10+ found. Install Python and try again.")
        }

        isCheckingEnvironment = false
        environmentChecked = true
    }

    var environmentReady: Bool {
        pythonPath != nil && (oasisStatus?.isInstalled ?? false)
    }

    // MARK: - Profile Generation

    func generateProfiles(nodeIds: [Int64] = [], maxAgents: Int = 30) async {
        isGeneratingProfiles = true
        profileProgress = 0
        statusMessage = "Starting profile generation\u{2026}"
        log("Generating agent profiles (max \(maxAgents) agents)\u{2026}")

        do {
            let generatedAgents = try await profileService.generateProfiles(
                simulationId: simulation.id,
                nodeIds: nodeIds,
                maxAgents: maxAgents,
                statusCallback: { [weak self] message in
                    self?.statusMessage = message
                    self?.log(message)
                },
                progressCallback: { [weak self] progress in
                    self?.profileProgress = progress
                }
            )

            agents = generatedAgents
            statusMessage = "Generated \(generatedAgents.count) agent profiles"
            log("Profile generation complete: \(generatedAgents.count) agents created")
            loadData()
        } catch {
            logError("Profile generation failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }

        isGeneratingProfiles = false
    }

    // MARK: - Simulation Control

    func startSimulation(config: SimulationConfig) async {
        statusMessage = "Exporting to OASIS\u{2026}"
        log("Starting simulation with \(config.maxRounds) rounds on \(config.platforms.joined(separator: ", "))")

        do {
            let configData = try JSONEncoder().encode(config)
            let configJson = String(data: configData, encoding: .utf8)
            try database.write { db in
                try db.execute(
                    sql: "UPDATE social_simulation SET config_json = ?, max_rounds = ? WHERE id = ?",
                    arguments: [configJson, config.maxRounds, simulation.id]
                )
            }

            log("Exporting simulation directory\u{2026}")
            let simDir = try await exportService.exportSimulation(
                simulationId: simulation.id,
                config: config
            )
            log("Exported to: \(simDir.path(percentEncoded: false))")

            subscribeToStatus()

            log("Launching OASIS subprocess\u{2026}")
            try await engine.startSimulation(
                simulationId: simulation.id,
                config: config,
                simDirectory: simDir
            )

            statusMessage = "Simulation running"
            log("Simulation subprocess launched")
        } catch {
            logError("Failed to start simulation: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
            status = .failed(error.localizedDescription)
        }
    }

    func stopSimulation() async {
        log("Stopping simulation\u{2026}")
        do {
            try await engine.stopSimulation(simulationId: simulation.id)
            log("Simulation stopped")
            loadData()
        } catch {
            logError("Failed to stop: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Status Subscription

    private func subscribeToStatus() {
        statusTask = Task { [weak self] in
            guard let self else { return }
            let stream = await engine.makeStatusStream()
            for await newStatus in stream {
                self.status = newStatus
                self.statusMessage = newStatus.displayText

                if case .running(let round, let total) = newStatus {
                    if round % 5 == 0 {
                        self.log("Round \(round)/\(total)")
                        self.loadData()
                    }
                }
                if case .completed = newStatus {
                    self.log("Simulation completed")
                    self.loadData()
                }
                if case .waitingForInterviews = newStatus {
                    self.log("Waiting for interviews")
                    self.loadData()
                }
                if case .failed(let msg) = newStatus {
                    self.logError("Simulation failed: \(msg)")
                }
            }
        }
    }

    // MARK: - Entity Classification

    private(set) var isClassifying = false
    private(set) var classificationProgress: Double = 0

    func classifyEntities() async {
        isClassifying = true
        classificationProgress = 0
        log("Starting entity classification\u{2026}")

        let service = NodeClassificationService()
        do {
            let count = try await service.classifyUntypedNodes(
                statusCallback: { [weak self] msg in self?.log(msg) },
                progressCallback: { [weak self] p in self?.classificationProgress = p }
            )
            log("Classified \(count) entities")
            loadData()
        } catch {
            logError("Classification failed: \(error.localizedDescription)")
            errorMessage = error.localizedDescription
        }
        isClassifying = false
    }

    // MARK: - Re-ingestion

    /// Re-ingests simulation data directly from the OASIS trace database.
    func reingestData() {
        guard let simDir = simulation.simDirectory else {
            logError("No simulation directory found")
            return
        }

        let oasisDBPath = URL(fileURLWithPath: simDir)
            .appending(path: "twitter/twitter.db").path

        guard FileManager.default.fileExists(atPath: oasisDBPath) else {
            logError("OASIS database not found at \(oasisDBPath)")
            return
        }

        // Build agent mapping: OASIS user_id → NewsComb agent ID
        var agentMapping: [Int: Int64] = [:]
        for agent in agents {
            if let agentId = agent.id, let oasisId = agent.oasisUserId {
                agentMapping[oasisId] = agentId
            }
        }

        guard !agentMapping.isEmpty else {
            logError("No agent mapping available for re-ingestion")
            return
        }

        let ingestionService = ActionIngestionService()
        do {
            let result = try ingestionService.reingestFromOasisDB(
                simulationId: simulation.id,
                oasisDBPath: oasisDBPath,
                agentMapping: agentMapping
            )
            log("Re-ingested: \(result.postsCreated) posts, \(result.interactionsCreated) interactions, \(result.connectionsCreated) connections")
            loadData()
        } catch {
            logError("Re-ingestion failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Computed

    var isRunning: Bool { status.isProcessing }
    var hasAgents: Bool { !agents.isEmpty }
    var hasPosts: Bool { !recentPosts.isEmpty }
}
