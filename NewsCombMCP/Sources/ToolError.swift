import Foundation

/// Errors returned to the MCP client as tool error responses.
struct ToolError: Error {
    let message: String

    static func missingParameter(_ name: String) -> ToolError {
        ToolError(message: "Missing required parameter: \(name)")
    }

    static func invalidParameter(_ name: String, detail: String) -> ToolError {
        ToolError(message: "Invalid parameter '\(name)': \(detail)")
    }

    static func notFound(_ entity: String) -> ToolError {
        ToolError(message: "Not found: \(entity)")
    }

    static func database(_ detail: String) -> ToolError {
        ToolError(message: "Database error: \(detail)")
    }
}
