import XCTest
import MCP
@testable import NewsCombApp

/// Argument-validation tests for the new MCP tools — `create_manual_feed`,
/// `ingest_article`, and `refresh_article`. These exercise only the parameter
/// decoding layer (which throws before reaching `MCPAppCoordinator.shared`),
/// so they don't require a live database. End-to-end coverage of the actual
/// ingestion logic lives in `ArticleIngestionServiceTests`.
final class MCPArticleIngestionToolTests: XCTestCase {

    // MARK: - create_manual_feed

    func testCreateManualFeedRejectsMissingTitle() async {
        await expectMCPError(messageContains: "title") {
            try await MCPCreateManualFeedTool.run(arguments: [:])
        }
    }

    func testCreateManualFeedRejectsEmptyTitle() async {
        await expectMCPError(messageContains: "title") {
            try await MCPCreateManualFeedTool.run(arguments: ["title": .string("")])
        }
    }

    // MARK: - ingest_article

    func testIngestArticleRejectsMissingSourceId() async {
        let args: [String: Value] = [
            "title": .string("T"),
            "body": .string(String(repeating: "x", count: 200))
        ]
        await expectMCPError(messageContains: "source_id") {
            try await MCPIngestArticleTool.run(arguments: args)
        }
    }

    func testIngestArticleRejectsMissingTitle() async {
        let args: [String: Value] = [
            "source_id": .int(1),
            "body": .string(String(repeating: "x", count: 200))
        ]
        await expectMCPError(messageContains: "title") {
            try await MCPIngestArticleTool.run(arguments: args)
        }
    }

    func testIngestArticleRejectsMissingBody() async {
        let args: [String: Value] = [
            "source_id": .int(1),
            "title": .string("T")
        ]
        await expectMCPError(messageContains: "body") {
            try await MCPIngestArticleTool.run(arguments: args)
        }
    }

    func testIngestArticleRejectsMalformedPubDate() async {
        let args: [String: Value] = [
            "source_id": .int(1),
            "title": .string("T"),
            "body": .string(String(repeating: "x", count: 200)),
            "pub_date": .string("not-a-date")
        ]
        await expectMCPError(messageContains: "pub_date") {
            try await MCPIngestArticleTool.run(arguments: args)
        }
    }

    // MARK: - refresh_article

    func testRefreshArticleRejectsMissingFeedItemId() async {
        await expectMCPError(messageContains: "feed_item_id") {
            try await MCPRefreshArticleTool.run(arguments: [:])
        }
    }

    // MARK: - Helpers

    /// Asserts that the closure throws an `MCPToolError` whose message
    /// contains `messageContains`.
    private func expectMCPError<T>(
        messageContains: String,
        file: StaticString = #file,
        line: UInt = #line,
        _ block: () async throws -> T
    ) async {
        do {
            _ = try await block()
            XCTFail("Expected MCPToolError, got success", file: file, line: line)
        } catch let error as MCPToolError {
            XCTAssertTrue(
                error.message.localizedStandardContains(messageContains),
                "Error message '\(error.message)' should contain '\(messageContains)'",
                file: file, line: line
            )
        } catch {
            XCTFail("Expected MCPToolError, got \(type(of: error)): \(error)", file: file, line: line)
        }
    }
}
