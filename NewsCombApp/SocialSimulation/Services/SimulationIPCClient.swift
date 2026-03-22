import Foundation
import OSLog

/// Actor that manages filesystem-based IPC with the OASIS subprocess.
///
/// Commands are serialized by actor isolation to prevent interleaved file writes.
/// File polling uses `@concurrent` to avoid blocking the actor's queue.
actor SimulationIPCClient {

    private let commandsDir: URL
    private let responsesDir: URL
    private let logger = Logger(subsystem: "com.newscomb", category: "SimulationIPC")

    init(simulationDir: URL) {
        self.commandsDir = simulationDir.appending(path: "ipc_commands")
        self.responsesDir = simulationDir.appending(path: "ipc_responses")
    }

    // MARK: - Public API

    /// Sends an IPC command and waits for the response.
    ///
    /// Actor isolation ensures commands are serialized — no two commands
    /// write to the filesystem concurrently.
    func sendCommand(
        _ command: IPCCommand,
        timeout: Duration = .seconds(60)
    ) async throws -> IPCResponse {
        let commandId = UUID().uuidString
        let commandFile = commandsDir.appending(path: "\(commandId).json")

        // Write command file (actor-isolated, safe from races)
        let data = try JSONEncoder().encode(command)
        try data.write(to: commandFile)
        logger.info("Sent IPC command \(command.commandType.rawValue, privacy: .public) [\(commandId.prefix(8), privacy: .public)]")

        // Poll for response — @concurrent so we don't block the actor
        let response = try await pollForResponse(commandId: commandId, timeout: timeout)

        // Cleanup command file
        try? FileManager.default.removeItem(at: commandFile)

        return response
    }

    /// Sends an interview command to a specific agent.
    func interview(agentId: Int, prompt: String, timeout: Duration = .seconds(120)) async throws -> String {
        let command = IPCCommand.interview(agentId: agentId, prompt: prompt)
        let response = try await sendCommand(command, timeout: timeout)

        guard response.success else {
            throw SimulationIPCError.interviewFailed(response.error ?? "Unknown error")
        }

        return response.result ?? ""
    }

    /// Sends a close environment command.
    func closeEnvironment() async throws {
        let command = IPCCommand.closeEnvironment()
        _ = try await sendCommand(command, timeout: .seconds(30))
        logger.info("OASIS environment closed via IPC")
    }

    // MARK: - File Polling

    /// Polls for a response file, running on the concurrent thread pool
    /// to avoid blocking the actor's serialized queue.
    @concurrent
    private func pollForResponse(
        commandId: String,
        timeout: Duration
    ) async throws -> IPCResponse {
        let responseFile = responsesDir.appending(path: "\(commandId).json")
        let deadline = ContinuousClock.now + timeout

        while ContinuousClock.now < deadline {
            try Task.checkCancellation()

            if FileManager.default.fileExists(atPath: responseFile.path()) {
                let data = try Data(contentsOf: responseFile)
                try? FileManager.default.removeItem(at: responseFile)
                return try JSONDecoder().decode(IPCResponse.self, from: data)
            }

            try await Task.sleep(for: .milliseconds(500))
        }

        throw SimulationIPCError.timeout(commandId: commandId)
    }
}

// MARK: - Errors

enum SimulationIPCError: LocalizedError {
    case timeout(commandId: String)
    case interviewFailed(String)

    var errorDescription: String? {
        switch self {
        case .timeout(let commandId):
            "IPC command timed out: \(commandId.prefix(8))"
        case .interviewFailed(let detail):
            "Interview failed: \(detail)"
        }
    }
}
