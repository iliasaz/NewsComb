import Foundation
import GRDB
import OSLog

/// Actor that orchestrates the OASIS simulation subprocess lifecycle.
///
/// Owns the `Process`, `SimulationIPCClient`, and `ActionLogMonitor` actors.
/// All subprocess state mutations are serialized by actor isolation.
/// Vends an `AsyncStream<SimulationStatus>` for UI updates.
actor SimulationEngine {

    // MARK: - Actor-Isolated State

    private var process: Process?
    private var ipcClient: SimulationIPCClient?
    private var logMonitor: ActionLogMonitor?
    private var monitorTask: Task<Void, Never>?
    private var status: SimulationStatus = .idle {
        didSet { statusContinuation?.yield(status) }
    }

    private var statusContinuation: AsyncStream<SimulationStatus>.Continuation?
    private var agentMapping: [Int: Int64] = [:]

    private let database = Database.shared
    private let ingestionService = ActionIngestionService()
    private let logger = Logger(subsystem: "com.newscomb", category: "SimulationEngine")

    // MARK: - Status Stream

    /// Creates an `AsyncStream` that emits status updates.
    ///
    /// Subscribe from a ViewModel:
    /// ```swift
    /// Task { for await status in engine.makeStatusStream() { self.status = status } }
    /// ```
    func makeStatusStream() -> AsyncStream<SimulationStatus> {
        AsyncStream { continuation in
            self.statusContinuation = continuation
            continuation.yield(self.status)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.clearContinuation() }
            }
        }
    }

    private func clearContinuation() {
        statusContinuation = nil
    }

    /// The current simulation status.
    var currentStatus: SimulationStatus {
        status
    }

    // MARK: - Simulation Lifecycle

    /// Starts the OASIS simulation subprocess.
    ///
    /// - Parameters:
    ///   - simulationId: The simulation to run.
    ///   - config: Simulation configuration.
    ///   - simDirectory: Path to the prepared simulation directory (from OasisExportService).
    func startSimulation(
        simulationId: String,
        config: SimulationConfig,
        simDirectory: URL
    ) async throws {
        guard process == nil else {
            throw SimulationEngineError.alreadyRunning
        }

        logger.info("Starting simulation \(simulationId, privacy: .public)")

        // Build agent mapping (OASIS user_id → NewsComb agent.id)
        agentMapping = try buildAgentMapping(simulationId: simulationId)

        // Update database status
        try database.write { db in
            try db.execute(
                sql: "UPDATE social_simulation SET status = 'running', started_at = unixepoch() WHERE id = ?",
                arguments: [simulationId]
            )
        }

        status = .launching

        // Create IPC client
        ipcClient = SimulationIPCClient(simulationDir: simDirectory)

        // Set up action log files to monitor
        var logFiles: [URL] = []
        for platform in config.platforms {
            let logFile = simDirectory.appending(path: platform).appending(path: "actions.jsonl")
            logFiles.append(logFile)
        }
        logMonitor = ActionLogMonitor(logFiles: logFiles)

        // Auto-detect Python path if using default
        let envService = OasisEnvironmentService()
        let pythonPath: String
        if config.pythonPath.isEmpty || config.pythonPath == AppSettings.defaultSimPythonPath {
            if let detected = await envService.detectPythonPath() {
                pythonPath = detected
            } else {
                throw SimulationEngineError.pythonNotFound
            }
        } else {
            pythonPath = config.pythonPath
        }

        // Verify OASIS is installed
        let oasisStatus = await envService.checkOasisInstalled(pythonPath: pythonPath)
        guard oasisStatus.isInstalled else {
            throw SimulationEngineError.oasisNotInstalled
        }

        // Load OpenRouter credentials from AppSettings to share with OASIS
        let (openRouterKey, openRouterModel) = try database.read { db -> (String?, String?) in
            let key = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterKey).fetchOne(db)?.value
            let model = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterModel).fetchOne(db)?.value
            return (key, model)
        }

        // Launch the Python subprocess
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: pythonPath)
        proc.arguments = [
            simDirectory.appending(path: "run_simulation.py").path(percentEncoded: false),
            "--config", simDirectory.appending(path: "simulation_config.json").path(percentEncoded: false),
            "--max-rounds", "\(config.maxRounds)"
        ]
        proc.currentDirectoryURL = simDirectory
        proc.environment = ProcessInfo.processInfo.environment.merging([
            "PYTHONUTF8": "1",
            "PYTHONIOENCODING": "utf-8",
            "OPENAI_API_KEY": openRouterKey ?? "",
            "OPENAI_API_BASE_URL": "https://openrouter.ai/api/v1",
            "OPENAI_MODEL_NAME": openRouterModel ?? "meta-llama/llama-4-maverick",
        ]) { _, new in new }

        // Capture stdout/stderr
        let outputPipe = Pipe()
        proc.standardOutput = outputPipe
        proc.standardError = outputPipe

        // Log subprocess output
        outputPipe.fileHandleForReading.readabilityHandler = { [logger] handle in
            let data = handle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                logger.info("[OASIS] \(text.trimmingCharacters(in: .whitespacesAndNewlines), privacy: .public)")
            }
        }

        // Monitor process termination
        proc.terminationHandler = { [weak self] terminatedProcess in
            Task { [weak self] in
                await self?.handleProcessTermination(
                    exitCode: terminatedProcess.terminationStatus,
                    simulationId: simulationId
                )
            }
        }

        try proc.run()
        process = proc
        logger.info("OASIS subprocess launched (PID \(proc.processIdentifier))")

        status = .running(round: 0, total: config.maxRounds)

        // Start monitoring action logs
        startActionMonitoring(simulationId: simulationId, maxRounds: config.maxRounds)
    }

    /// Stops the simulation gracefully via IPC, then terminates the process.
    func stopSimulation(simulationId: String) async throws {
        logger.info("Stopping simulation \(simulationId, privacy: .public)")

        // Try graceful shutdown via IPC
        if let ipc = ipcClient {
            do {
                try await ipc.closeEnvironment()
            } catch {
                logger.warning("IPC close failed, will terminate process: \(error.localizedDescription, privacy: .public)")
            }
        }

        // Cancel monitoring
        monitorTask?.cancel()
        monitorTask = nil
        if let monitor = logMonitor {
            await monitor.stopMonitoring()
        }

        // Terminate process if still running
        if let proc = process, proc.isRunning {
            proc.terminate()
            logger.info("OASIS subprocess terminated")
        }
        process = nil

        // Update database
        try database.write { db in
            try db.execute(
                sql: "UPDATE social_simulation SET status = 'completed', completed_at = unixepoch() WHERE id = ?",
                arguments: [simulationId]
            )
        }

        status = .completed
    }

    /// Access to the IPC client for interviews while simulation is running.
    func interviewAgent(agentId: Int, prompt: String) async throws -> String {
        guard let ipc = ipcClient else {
            throw SimulationEngineError.notRunning
        }
        return try await ipc.interview(agentId: agentId, prompt: prompt)
    }

    // MARK: - Action Monitoring

    /// Starts the background task that monitors OASIS action logs and ingests them.
    private func startActionMonitoring(simulationId: String, maxRounds: Int) {
        guard let monitor = logMonitor else { return }

        monitorTask = Task { [weak self, ingestionService, agentMapping] in
            let stream = await monitor.startMonitoring()

            for await actions in stream {
                guard let self else { break }

                // Ingest actions into the social graph
                do {
                    try ingestionService.ingest(
                        actions: actions,
                        simulationId: simulationId,
                        agentMapping: agentMapping
                    )
                } catch {
                    await self.logger.error("Action ingestion failed: \(error.localizedDescription, privacy: .public)")
                }

                // Update round progress
                if let latestRound = ingestionService.latestRound(in: actions) {
                    await self.updateRound(round: latestRound + 1, total: maxRounds, simulationId: simulationId)
                }

                // Check for simulation end
                if actions.contains(where: \.isSimulationEnd) {
                    await self.handleSimulationEnd(simulationId: simulationId)
                    break
                }
            }
        }
    }

    private func updateRound(round: Int, total: Int, simulationId: String) {
        status = .running(round: round, total: total)

        try? database.write { db in
            try db.execute(
                sql: "UPDATE social_simulation SET round_count = ? WHERE id = ?",
                arguments: [round, simulationId]
            )
        }
    }

    private func handleSimulationEnd(simulationId: String) {
        logger.info("Simulation \(simulationId, privacy: .public) completed")

        try? database.write { db in
            try db.execute(
                sql: "UPDATE social_simulation SET status = 'completed', completed_at = unixepoch() WHERE id = ?",
                arguments: [simulationId]
            )
        }

        status = .waitingForInterviews
    }

    private func handleProcessTermination(exitCode: Int32, simulationId: String) {
        if exitCode == 0 {
            logger.info("OASIS subprocess exited normally")
        } else {
            logger.error("OASIS subprocess exited with code \(exitCode)")

            try? database.write { db in
                try db.execute(
                    sql: "UPDATE social_simulation SET status = 'completed', completed_at = unixepoch() WHERE id = ?",
                    arguments: [simulationId]
                )
            }

            if status.isActive {
                status = .failed("OASIS process exited with code \(exitCode)")
            }
        }

        process = nil
    }

    // MARK: - Helpers

    private func buildAgentMapping(simulationId: String) throws -> [Int: Int64] {
        try database.read { db in
            let agents = try SocialAgent
                .filter(SocialAgent.Columns.simulationId == simulationId)
                .fetchAll(db)

            var mapping: [Int: Int64] = [:]
            for agent in agents {
                if let oasisId = agent.oasisUserId, let agentId = agent.id {
                    mapping[oasisId] = agentId
                }
            }
            return mapping
        }
    }
}

// MARK: - Errors

enum SimulationEngineError: LocalizedError {
    case alreadyRunning
    case notRunning
    case pythonNotFound
    case oasisNotInstalled

    var errorDescription: String? {
        switch self {
        case .alreadyRunning:
            "A simulation is already running."
        case .notRunning:
            "No simulation is currently running."
        case .pythonNotFound:
            "Python 3.10+ was not found. Install Python and try again."
        case .oasisNotInstalled:
            "camel-oasis is not installed. Run: pip install camel-oasis"
        }
    }
}
