import Foundation

/// A command sent to the OASIS subprocess via filesystem IPC.
///
/// Commands are written as JSON files to the `ipc_commands/` directory.
/// The OASIS subprocess polls this directory and processes commands.
struct IPCCommand: Codable, Sendable {
    var commandType: CommandType
    var payload: [String: String]

    enum CommandType: String, Codable, Sendable {
        case interview = "INTERVIEW"
        case batchInterview = "BATCH_INTERVIEW"
        case closeEnv = "CLOSE_ENV"
    }

    enum CodingKeys: String, CodingKey {
        case commandType = "command_type"
        case payload
    }

    /// Creates an interview command for a single agent.
    static func interview(agentId: Int, prompt: String) -> IPCCommand {
        IPCCommand(
            commandType: .interview,
            payload: ["agent_id": "\(agentId)", "prompt": prompt]
        )
    }

    /// Creates a command to gracefully close the OASIS environment.
    static func closeEnvironment() -> IPCCommand {
        IPCCommand(commandType: .closeEnv, payload: [:])
    }
}
