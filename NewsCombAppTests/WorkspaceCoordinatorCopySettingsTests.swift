import XCTest
@testable import NewsCombApp

@MainActor
final class WorkspaceCoordinatorCopySettingsTests: XCTestCase {

    private var tempRoot: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspaceDefaults: WorkspaceDefaults!
    private var sut: WorkspaceCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "newscomb.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        workspaceDefaults = WorkspaceDefaults(defaults: defaults)
        sut = WorkspaceCoordinator(defaults: workspaceDefaults, busyReasonsProvider: { [] })
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "CopySettings-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
        Database.resetCurrentForTesting()
        sut = nil
        workspaceDefaults = nil
        defaults = nil
        suiteName = nil
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Helpers

    private func writeSetting(_ key: String, value: String, in db: Database) throws {
        try db.dbQueue.write { conn in
            try conn.execute(sql: """
                INSERT INTO app_settings (key, value) VALUES (?, ?)
                ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [key, value])
        }
    }

    private func readSetting(_ key: String, in db: Database) throws -> String? {
        try db.dbQueue.read { conn in
            try String.fetchOne(conn, sql: "SELECT value FROM app_settings WHERE key = ?", arguments: [key])
        }
    }

    // MARK: - copyAppSettings(from:to:)

    func testCopyOverwritesTargetSeedDefaultsWithSourceValues() throws {
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        let sourceDB = try Database(directory: sourceDir)

        // Override two settings the seed sets to defaults.
        try writeSetting("llm_provider", value: "openrouter", in: sourceDB)
        try writeSetting("ollama_model", value: "qwen2.5:14b", in: sourceDB)

        try sut.copyAppSettings(from: sourceDir, to: targetDir)

        let targetDB = try Database(directory: targetDir)
        XCTAssertEqual(try readSetting("llm_provider", in: targetDB), "openrouter")
        XCTAssertEqual(try readSetting("ollama_model", in: targetDB), "qwen2.5:14b")
    }

    func testCopyCarriesUserOnlyKeysIntoTarget() throws {
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        let sourceDB = try Database(directory: sourceDir)

        // Settings the user added (e.g. an API key not in the seed defaults).
        try writeSetting("openrouter_key", value: "sk-test-12345", in: sourceDB)

        try sut.copyAppSettings(from: sourceDir, to: targetDir)

        let targetDB = try Database(directory: targetDir)
        XCTAssertEqual(try readSetting("openrouter_key", in: targetDB), "sk-test-12345")
    }

    func testCopyPreservesTargetSeedKeysSourceLacks() throws {
        // If the source DB pre-dates a setting that the target's migration
        // seeds (e.g. a new default added in a future schema), copy should
        // keep the target's seeded value rather than blanking it.
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        let sourceDB = try Database(directory: sourceDir)

        // Remove a known seeded key from the source so it appears "missing".
        try sourceDB.dbQueue.write { conn in
            try conn.execute(sql: "DELETE FROM app_settings WHERE key = ?", arguments: ["embedding_provider"])
        }

        try sut.copyAppSettings(from: sourceDir, to: targetDir)

        let targetDB = try Database(directory: targetDir)
        // Target's seed should still be present.
        let value = try readSetting("embedding_provider", in: targetDB)
        XCTAssertNotNil(value)
        XCTAssertFalse(value!.isEmpty)
    }

    func testCopyCountsAllSourceRows() throws {
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        let sourceDB = try Database(directory: sourceDir)

        // Add 3 user-only keys.
        try writeSetting("custom_key_1", value: "v1", in: sourceDB)
        try writeSetting("custom_key_2", value: "v2", in: sourceDB)
        try writeSetting("custom_key_3", value: "v3", in: sourceDB)

        try sut.copyAppSettings(from: sourceDir, to: targetDir)

        let targetDB = try Database(directory: targetDir)
        for i in 1...3 {
            XCTAssertEqual(try readSetting("custom_key_\(i)", in: targetDB), "v\(i)")
        }
    }

    // MARK: - copyAppSettingsFromCurrent(to:)

    func testCopyFromCurrentReturnsFalseWhenNoActive() throws {
        XCTAssertNil(sut.active)
        let target = tempRoot.appending(path: "Target")
        let copied = try sut.copyAppSettingsFromCurrent(to: target)
        XCTAssertFalse(copied)
    }

    func testCopyFromCurrentReturnsFalseWhenTargetEqualsActive() throws {
        let dir = tempRoot.appending(path: "Same")
        try sut.openWorkspace(at: dir)
        let copied = try sut.copyAppSettingsFromCurrent(to: dir)
        XCTAssertFalse(copied, "Copying to the active workspace should be a no-op")
    }

    func testCopyFromCurrentSucceedsAndCarriesValues() throws {
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")

        // Make Source the active workspace, then put a known value in it.
        try sut.openWorkspace(at: sourceDir)
        try writeSetting("openrouter_key", value: "sk-current-99", in: Database.current)

        let copied = try sut.copyAppSettingsFromCurrent(to: targetDir)
        XCTAssertTrue(copied)

        let targetDB = try Database(directory: targetDir)
        XCTAssertEqual(try readSetting("openrouter_key", in: targetDB), "sk-current-99")
    }

    // MARK: - Non-portable schema-state keys

    // MARK: - provisionNewWorkspace

    func testProvisionNewWorkspaceCopiesSettings() throws {
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        try sut.openWorkspace(at: sourceDir)
        try writeSetting("openrouter_key", value: "sk-x-77", in: Database.current)

        let provisioned = try sut.provisionNewWorkspace(at: targetDir)
        XCTAssertTrue(provisioned)

        let targetDB = try Database(directory: targetDir)
        XCTAssertEqual(try readSetting("openrouter_key", in: targetDB), "sk-x-77")
    }

    func testProvisionNewWorkspaceLeavesNoFeeds() throws {
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        try sut.openWorkspace(at: sourceDir)
        try sut.provisionNewWorkspace(at: targetDir)

        let targetDB = try Database(directory: targetDir)
        let count = try targetDB.dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source")
        }
        XCTAssertEqual(count, 0, "Provisioned workspace should have no RSS feeds")
    }

    func testProvisionedWorkspaceDoesNotAcquireFeedsAfterReopen() throws {
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        try sut.openWorkspace(at: sourceDir)
        try sut.provisionNewWorkspace(at: targetDir)

        // Two consecutive reopens — migrate runs each time, but auto-seeding
        // is gone so feeds remain empty regardless.
        for _ in 0..<2 {
            let reopened = try Database(directory: targetDir)
            let count = try reopened.dbQueue.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source")
            }
            XCTAssertEqual(count, 0, "Reopens must not introduce feeds")
        }
    }

    func testProvisionReturnsFalseWhenNoActive() throws {
        XCTAssertNil(sut.active)
        let target = tempRoot.appending(path: "Target")
        XCTAssertFalse(try sut.provisionNewWorkspace(at: target))
    }

    func testProvisionReturnsFalseWhenTargetEqualsActive() throws {
        let dir = tempRoot.appending(path: "Same")
        try sut.openWorkspace(at: dir)
        XCTAssertFalse(try sut.provisionNewWorkspace(at: dir))
    }

    // MARK: - Schema-state exclusions

    func testCopyDoesNotOverwriteActiveEmbeddingDimension() throws {
        // active_embedding_dimension is schema metadata — it tracks the size
        // the vec0 tables were physically created with. Copying it would make
        // `Database.migrate` skip the vec0 rebuild on next launch even though
        // the carried-over `embedding_dimension` differs from on-disk schema.
        let sourceDir = tempRoot.appending(path: "Source")
        let targetDir = tempRoot.appending(path: "Target")
        let sourceDB = try Database(directory: sourceDir)

        // Source claims its tables are 1024-d (lying for the test — we don't
        // actually rebuild here, we just want to verify the copy skips this key).
        try writeSetting(AppSettings.activeEmbeddingDimension, value: "1024", in: sourceDB)
        // Also bump the user-intent setting so the test is realistic.
        try writeSetting(AppSettings.embeddingDimension, value: "1024", in: sourceDB)

        // Capture the target's seeded value before the copy.
        let targetDB = try Database(directory: targetDir)
        let preCopyActiveDim = try readSetting(AppSettings.activeEmbeddingDimension, in: targetDB)

        try sut.copyAppSettings(from: sourceDir, to: targetDir)

        // User intent: should now match source.
        XCTAssertEqual(try readSetting(AppSettings.embeddingDimension, in: targetDB), "1024")
        // Schema state: must remain whatever the target's own migration set it to.
        let postCopyActiveDim = try readSetting(AppSettings.activeEmbeddingDimension, in: targetDB)
        XCTAssertEqual(
            postCopyActiveDim, preCopyActiveDim,
            "active_embedding_dimension must not be copied — it tracks the target's vec0 table size"
        )
    }
}
