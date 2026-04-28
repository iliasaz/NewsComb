import XCTest
import GRDB
@testable import NewsCombApp

/// Direct tests for `Database.init(directory:)` and the
/// `current` / `setCurrent(_:)` accessors introduced for the workspace feature.
final class DatabaseWorkspaceInitTests: XCTestCase {

    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "DBInitTests-\(UUID().uuidString)")
    }

    override func tearDown() async throws {
        Database.resetCurrentForTesting()
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        try await super.tearDown()
    }

    func testInitCreatesDirectoryWhenAbsent() throws {
        let dir = tempRoot.appending(path: "Brand/New/Path")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
        _ = try Database(directory: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path(percentEncoded: false)))
    }

    func testInitCreatesSQLiteFile() throws {
        let dir = tempRoot.appending(path: "Alpha")
        _ = try Database(directory: dir)
        let dbFile = dir.appending(path: "newscomb.sqlite")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbFile.path(percentEncoded: false)))
    }

    func testInitRunsMigrationCreatingCoreTables() throws {
        let dir = tempRoot.appending(path: "Beta")
        let db = try Database(directory: dir)

        // Spot-check several core tables created in migrate()
        let expected = ["rss_source", "feed_item", "app_settings", "hypergraph_node", "hypergraph_edge"]
        let names = try db.dbQueue.read { db -> Set<String> in
            let rows = try Row.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return Set(rows.compactMap { $0["name"] as String? })
        }
        for table in expected {
            XCTAssertTrue(names.contains(table), "Expected table '\(table)' to exist after migrate()")
        }
    }

    func testWorkspaceDirectoryIsCanonicalized() throws {
        // Trailing slash should be stripped; the property should round-trip
        // to the same URL as the canonical workspace directory.
        let dir = tempRoot.appending(path: "Gamma/")
        let db = try Database(directory: dir)
        XCTAssertEqual(db.workspaceDirectory, tempRoot.appending(path: "Gamma").canonicalDirectoryURL)
    }

    func testTwoInstancesAtDifferentPathsAreIndependent() throws {
        let dirA = tempRoot.appending(path: "A")
        let dirB = tempRoot.appending(path: "B")
        let dbA = try Database(directory: dirA)
        let dbB = try Database(directory: dirB)
        XCTAssertNotEqual(dbA.workspaceDirectory, dbB.workspaceDirectory)
        XCTAssertNotEqual(dbA.dbQueue.path, dbB.dbQueue.path)
    }

    // MARK: - current / setCurrent

    func testSetCurrentReplacesActiveDatabase() throws {
        let dirA = tempRoot.appending(path: "First")
        let dirB = tempRoot.appending(path: "Second")
        let dbA = try Database(directory: dirA)
        let dbB = try Database(directory: dirB)

        Database.setCurrent(dbA)
        XCTAssertEqual(Database.current.workspaceDirectory, dirA.canonicalDirectoryURL)

        Database.setCurrent(dbB)
        XCTAssertEqual(Database.current.workspaceDirectory, dirB.canonicalDirectoryURL)
    }

    func testResetCurrentForTestingClearsActive() throws {
        let dir = tempRoot.appending(path: "Reset")
        let db = try Database(directory: dir)
        Database.setCurrent(db)
        XCTAssertEqual(Database.current.workspaceDirectory, dir.canonicalDirectoryURL)
        Database.resetCurrentForTesting()
        // After reset, accessing `current` lazy-bootstraps to legacy. We don't
        // assert on the bootstrapped value here (it would touch the user's
        // real Application Support); we only verify that reset doesn't crash
        // and a subsequent setCurrent works.
        Database.setCurrent(db)
        XCTAssertEqual(Database.current.workspaceDirectory, dir.canonicalDirectoryURL)
    }
}
