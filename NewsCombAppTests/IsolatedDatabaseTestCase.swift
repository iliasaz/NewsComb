import Foundation
import XCTest
@testable import NewsCombApp

/// XCTestCase base class that gives each test method a fresh, isolated
/// `Database` installed at `Database.current`, rooted at a unique temporary
/// directory.
///
/// Why this exists: many production services capture `Database.current` at
/// init time (e.g. `private let database = Database.current`). When a test
/// instantiates such a service without first calling `Database.setCurrent(_:)`,
/// the service captures whatever the lazy-fallback path returns — and under
/// `xcodebuild test`'s default per-class parallelism, that path could race
/// across runner processes against a shared SQLite file. See issue #29.
///
/// Subclassing this base class makes the per-test setup explicit and
/// guarantees `Database.setCurrent` runs before any test body, so the
/// singleton always points at an isolated location no other test (or
/// runner process) can reach.
class IsolatedDatabaseTestCase: XCTestCase {

    /// Filesystem location of the per-test workspace. Owned by this base
    /// class — subclasses should treat it as read-only.
    private(set) var workspaceDirectory: URL!

    /// The Database instance installed at `Database.current` for this test.
    /// Subclasses can use this directly to seed test fixtures via
    /// `database.write { db in ... }` instead of going through `Database.current`.
    private(set) var database: Database!

    override func setUp() async throws {
        try await super.setUp()
        workspaceDirectory = FileManager.default.temporaryDirectory
            .appending(path: "IsolatedDB-\(UUID().uuidString)")
        database = try Database(directory: workspaceDirectory)
        Database.setCurrent(database)
    }

    override func tearDown() async throws {
        Database.resetCurrentForTesting()
        if let workspaceDirectory {
            try? FileManager.default.removeItem(at: workspaceDirectory)
        }
        workspaceDirectory = nil
        database = nil
        try await super.tearDown()
    }
}
