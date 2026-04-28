import XCTest
@testable import NewsCombApp

@MainActor
final class WorkspaceCoordinatorSwitchTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspaceDefaults: WorkspaceDefaults!
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "newscomb.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        workspaceDefaults = WorkspaceDefaults(defaults: defaults)
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "SwitchTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempRoot)
        Database.resetCurrentForTesting()
        workspaceDefaults = nil
        defaults = nil
        suiteName = nil
        tempRoot = nil
        try await super.tearDown()
    }

    // MARK: - Busy gating

    func testCanSwitchWorkspaceTrueWhenNoReasons() {
        let sut = WorkspaceCoordinator(defaults: workspaceDefaults, busyReasonsProvider: { [] })
        XCTAssertTrue(sut.canSwitchWorkspace)
        XCTAssertEqual(sut.busyReasons, [])
    }

    func testCanSwitchWorkspaceFalseWhenBusy() {
        let sut = WorkspaceCoordinator(
            defaults: workspaceDefaults,
            busyReasonsProvider: { ["processing hypergraph"] }
        )
        XCTAssertFalse(sut.canSwitchWorkspace)
        XCTAssertEqual(sut.busyReasons, ["processing hypergraph"])
    }

    // MARK: - switchWorkspace

    func testSwitchSucceedsWhenNotBusy() throws {
        let sut = WorkspaceCoordinator(defaults: workspaceDefaults, busyReasonsProvider: { [] })
        let target = tempRoot.appending(path: "Target")
        let result = try sut.switchWorkspace(to: target)
        XCTAssertEqual(result.directory, target.canonicalDirectoryURL)
    }

    func testSwitchRefusesWhenBusy() {
        let sut = WorkspaceCoordinator(
            defaults: workspaceDefaults,
            busyReasonsProvider: { ["processing hypergraph", "refreshing feeds"] }
        )
        let target = tempRoot.appending(path: "Target")
        XCTAssertThrowsError(try sut.switchWorkspace(to: target)) { error in
            guard case let WorkspaceCoordinator.SwitchError.busy(reasons) = error else {
                return XCTFail("Expected .busy, got \(error)")
            }
            XCTAssertEqual(reasons, ["processing hypergraph", "refreshing feeds"])
        }
    }

    func testSwitchPersistsLastOpened() throws {
        let sut = WorkspaceCoordinator(defaults: workspaceDefaults, busyReasonsProvider: { [] })
        let target = tempRoot.appending(path: "Target")
        try sut.switchWorkspace(to: target)
        XCTAssertEqual(workspaceDefaults.lastOpenedWorkspace, target.canonicalDirectoryURL)
    }

    func testSwitchPushesToRecents() throws {
        let sut = WorkspaceCoordinator(defaults: workspaceDefaults, busyReasonsProvider: { [] })
        let target = tempRoot.appending(path: "Target")
        try sut.switchWorkspace(to: target)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.first, target.canonicalDirectoryURL)
    }

    func testSwitchDoesNotChangeActiveOrOpenDatabase() throws {
        // switchWorkspace is "stage + relaunch"; it should not mutate live state.
        let sut = WorkspaceCoordinator(defaults: workspaceDefaults, busyReasonsProvider: { [] })
        XCTAssertNil(sut.active)
        let target = tempRoot.appending(path: "Target")
        try sut.switchWorkspace(to: target)
        XCTAssertNil(sut.active, "switchWorkspace should not set active — caller relaunches")
        // No newscomb.sqlite created at the target — the caller's bootstrap will do it.
        let dbFile = target.appending(path: Workspace.databaseFileName)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dbFile.path(percentEncoded: false)))
    }

    func testSwitchErrorDescriptionListsAllReasons() {
        let error = WorkspaceCoordinator.SwitchError.busy(reasons: ["a", "b", "c"])
        XCTAssertEqual(error.errorDescription, "Cannot switch workspace while busy: a, b, c")
    }
}
