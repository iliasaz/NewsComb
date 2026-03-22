import Foundation

/// A response received from the OASIS subprocess via filesystem IPC.
///
/// Responses are written as JSON files to the `ipc_responses/` directory,
/// keyed by the same command ID used in the request.
struct IPCResponse: Codable, Sendable {
    var success: Bool
    var result: String?
    var error: String?

    enum CodingKeys: String, CodingKey {
        case success, result, error
    }
}
