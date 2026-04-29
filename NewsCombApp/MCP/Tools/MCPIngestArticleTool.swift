import Foundation
import MCP

/// Ingests an MCP-supplied article into a manual feed. The body becomes the
/// stored `full_content`; optional `link`, `author`, `pub_date`, and `guid`
/// fields are passed through. Re-ingesting the same `(source_id, guid)`
/// updates the existing row instead of duplicating.
enum MCPIngestArticleTool {
    static func run(arguments: [String: Value]) async throws -> String {
        guard let sourceId = arguments["source_id"]?.intValue.map(Int64.init) else {
            throw MCPToolError.missingParameter("source_id")
        }
        guard let title = arguments["title"]?.stringValue, !title.isEmpty else {
            throw MCPToolError.missingParameter("title")
        }
        guard let body = arguments["body"]?.stringValue, !body.isEmpty else {
            throw MCPToolError.missingParameter("body")
        }

        let link = arguments["link"]?.stringValue
        let author = arguments["author"]?.stringValue
        let guid = arguments["guid"]?.stringValue

        let pubDate: Date?
        if let raw = arguments["pub_date"]?.stringValue, !raw.isEmpty {
            guard let parsed = parseISO8601(raw) else {
                throw MCPToolError.invalidParameter("pub_date", detail: "expected ISO8601 (e.g. 2026-04-29T12:00:00Z), got '\(raw)'")
            }
            pubDate = parsed
        } else {
            pubDate = nil
        }

        return await MCPAppCoordinator.shared.ingestArticle(
            sourceId: sourceId,
            title: title,
            body: body,
            link: link,
            author: author,
            pubDate: pubDate,
            guid: guid
        )
    }

    private static func parseISO8601(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: string)
    }
}
