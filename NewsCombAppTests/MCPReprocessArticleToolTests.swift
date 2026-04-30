import XCTest
import MCP
@testable import NewsCombApp

/// Argument-validation tests for the `reprocess_article` MCP tool. These
/// exercise only the parameter decoding layer (which throws before reaching
/// `MCPAppCoordinator.shared`), so they don't require a live database or LLM.
/// End-to-end coverage of the deletion logic lives in
/// `HypergraphReprocessArticleTests`.
final class MCPReprocessArticleToolTests: XCTestCase {

    func testReprocessArticleRejectsMissingFeedItemId() async {
        await expectMCPError(messageContains: "feed_item_id") {
            try await MCPReprocessArticleTool.run(arguments: [:])
        }
    }

    // MARK: - Helpers

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
