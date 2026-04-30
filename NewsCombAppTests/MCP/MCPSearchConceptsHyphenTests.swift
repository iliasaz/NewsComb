import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Verifies that `search_concepts` survives queries containing FTS5-special
/// characters — hyphens, slashes, embedded quotes — that previously caused
/// SQLite to throw `"no such column: <token>"` because the raw user string
/// was passed through to `MATCH` unsanitized (issue #31).
final class MCPSearchConceptsHyphenTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPSearchConceptsHyphenTests-\(UUID().uuidString)")
        let database = try Database(directory: tempRoot)
        Database.setCurrent(database)
    }

    override func tearDown() async throws {
        Database.resetCurrentForTesting()
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Hyphenated / special-character queries

    func testHyphenatedQueryDoesNotThrow() throws {
        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("sqlite-vec")]
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.localizedStandardContains("sqlite-vec"))
    }

    func testSlashAndHyphenQueryDoesNotThrow() throws {
        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("meta-llama/llama-4-maverick")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testHTTPHeaderStyleQueryDoesNotThrow() throws {
        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("X-Workspace")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testQueryWithEmbeddedQuoteDoesNotThrow() throws {
        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("she said \"hi-there\"")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testPlainIdentifierQueryStillWorks() throws {
        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("WorkspaceCoordinator")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Sanitizer unit tests

    func testSanitizerWrapsAsPhrase() {
        XCTAssertEqual(sanitizeForFTS5("sqlite-vec"), "\"sqlite-vec\"")
    }

    func testSanitizerEscapesEmbeddedQuotes() {
        // FTS5 phrase literals escape `"` by doubling.
        XCTAssertEqual(sanitizeForFTS5("she said \"hi\""), "\"she said \"\"hi\"\"\"")
    }

    func testSanitizerPreservesPlainText() {
        XCTAssertEqual(sanitizeForFTS5("WorkspaceCoordinator"), "\"WorkspaceCoordinator\"")
    }

    // MARK: - Argument validation

    func testMissingQueryThrows() {
        XCTAssertThrowsError(try MCPSearchConceptsTool.run(arguments: [:])) { error in
            guard let mcpError = error as? MCPToolError else {
                XCTFail("Expected MCPToolError, got \(type(of: error))")
                return
            }
            XCTAssertTrue(mcpError.message.localizedStandardContains("query"))
        }
    }

    func testEmptyQueryThrows() {
        XCTAssertThrowsError(
            try MCPSearchConceptsTool.run(arguments: ["query": .string("")])
        )
    }
}
