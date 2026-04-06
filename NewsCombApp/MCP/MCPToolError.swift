import Foundation

/// Error type for MCP tool operations.
struct MCPToolError: Error, Sendable {
    let message: String

    static func missingParameter(_ name: String) -> MCPToolError {
        MCPToolError(message: "Missing required parameter: \(name)")
    }

    static func invalidParameter(_ name: String, detail: String) -> MCPToolError {
        MCPToolError(message: "Invalid parameter '\(name)': \(detail)")
    }

    static func notFound(_ detail: String) -> MCPToolError {
        MCPToolError(message: "Not found: \(detail)")
    }

    static func database(_ error: any Error) -> MCPToolError {
        MCPToolError(message: "Database error: \(error.localizedDescription)")
    }
}
