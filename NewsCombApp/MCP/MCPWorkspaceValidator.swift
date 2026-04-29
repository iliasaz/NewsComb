import Foundation

/// Validates an MCP request's `X-Workspace` header against the app's active
/// workspace. Pure value-level logic — no I/O, no dependencies — so it can be
/// unit-tested without standing up the HTTP server or the coordinator.
///
/// Backward compatibility: if the bridge does not send the header (older
/// versions, manual curl calls), validation passes. Only requests that
/// explicitly assert a workspace are checked.
enum MCPWorkspaceValidator {

    static let headerName = "X-Workspace"

    enum ValidationFailure: Equatable, Sendable {
        case noActiveWorkspace(requested: URL)
        case mismatch(active: URL, requested: URL)

        var message: String {
            switch self {
            case .noActiveWorkspace(let requested):
                return "NewsComb has no active workspace. The bridge requested '\(requested.path(percentEncoded: false))'. Open this workspace in the NewsComb app first."
            case .mismatch(let active, let requested):
                return "Workspace mismatch: app is on '\(active.path(percentEncoded: false))', bridge requested '\(requested.path(percentEncoded: false))'. Open the matching workspace via File → Open Workspace in NewsComb, or update the bridge's --workspace argument."
            }
        }

        /// JSON-RPC error code (server-defined range -32000…-32099).
        var code: Int { -32001 }
    }

    /// Returns `nil` to allow the request, or a `ValidationFailure` describing why
    /// the request should be rejected.
    static func validate(
        requestedHeader: String?,
        active: URL?
    ) -> ValidationFailure? {
        guard let requestedPath = requestedHeader, !requestedPath.isEmpty else {
            return nil
        }
        let requested = URL(filePath: requestedPath).canonicalDirectoryURL
        guard let active else {
            return .noActiveWorkspace(requested: requested)
        }
        if active == requested { return nil }
        return .mismatch(active: active, requested: requested)
    }
}
