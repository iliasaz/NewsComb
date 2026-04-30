import XCTest
import Foundation
import GRDB
import MCP
@testable import NewsCombApp

/// Verifies that `search_chunks` survives queries containing FTS5-special
/// characters — hyphens, slashes, embedded quotes — that previously caused
/// SQLite to throw `"no such column: <token>"` because the raw user string
/// was passed through to `MATCH` unsanitized (issue #31).
///
/// Tests run against a freshly migrated empty database. The FTS5 query
/// parser still validates the MATCH expression on an empty index, so an
/// unsanitized hyphenated query throws there too — making an empty corpus
/// a sufficient regression probe.
final class MCPSearchChunksHyphenTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "MCPSearchChunksHyphenTests-\(UUID().uuidString)")
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
        let result = try MCPSearchChunksTool.run(
            arguments: ["query": .string("sqlite-vec")]
        )
        XCTAssertFalse(result.isEmpty)
        XCTAssertTrue(result.localizedStandardContains("sqlite-vec"))
    }

    func testSlashAndHyphenQueryDoesNotThrow() throws {
        let result = try MCPSearchChunksTool.run(
            arguments: ["query": .string("meta-llama/llama-4-maverick")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testHTTPHeaderStyleQueryDoesNotThrow() throws {
        let result = try MCPSearchChunksTool.run(
            arguments: ["query": .string("X-Workspace")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testQueryWithEmbeddedQuoteDoesNotThrow() throws {
        // Internal double quotes must be escaped (doubled) to avoid breaking
        // the FTS5 phrase literal — otherwise SQLite would raise a syntax error.
        let result = try MCPSearchChunksTool.run(
            arguments: ["query": .string("she said \"hi-there\"")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    func testPlainIdentifierQueryStillWorks() throws {
        let result = try MCPSearchChunksTool.run(
            arguments: ["query": .string("WorkspaceCoordinator")]
        )
        XCTAssertFalse(result.isEmpty)
    }

    // MARK: - Argument validation

    func testMissingQueryThrows() {
        XCTAssertThrowsError(try MCPSearchChunksTool.run(arguments: [:])) { error in
            guard let mcpError = error as? MCPToolError else {
                XCTFail("Expected MCPToolError, got \(type(of: error))")
                return
            }
            XCTAssertTrue(mcpError.message.localizedStandardContains("query"))
        }
    }

    func testEmptyQueryThrows() {
        XCTAssertThrowsError(
            try MCPSearchChunksTool.run(arguments: ["query": .string("")])
        )
    }
}
