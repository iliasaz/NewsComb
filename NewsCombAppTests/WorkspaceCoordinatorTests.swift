import XCTest
@testable import NewsCombApp

@MainActor
final class WorkspaceCoordinatorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspaceDefaults: WorkspaceDefaults!
    private var sut: WorkspaceCoordinator!
    private var tempRoot: URL!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "newscomb.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        workspaceDefaults = WorkspaceDefaults(defaults: defaults)
        sut = WorkspaceCoordinator(defaults: workspaceDefaults)
        tempRoot = FileManager.default.temporaryDirectory
            .appending(path: "WorkspaceCoordinatorTests-\(UUID().uuidString)")
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

    // MARK: - Bookkeeping (recordActive)

    func testActiveIsNilOnInit() {
        XCTAssertNil(sut.active)
    }

    func testRecordActiveStoresWorkspace() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Tech"))
        sut.recordActive(workspace)
        XCTAssertEqual(sut.active, workspace)
    }

    func testRecordActivePersistsLastOpened() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Tech"))
        sut.recordActive(workspace)
        XCTAssertEqual(workspaceDefaults.lastOpenedWorkspace, workspace.directory)
    }

    func testRecordActivePushesToRecents() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Tech"))
        sut.recordActive(workspace)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.first, workspace.directory)
    }

    func testRecordActiveTwiceMovesMostRecentToFront() {
        let a = Workspace(directory: URL(filePath: "/tmp/A"))
        let b = Workspace(directory: URL(filePath: "/tmp/B"))
        sut.recordActive(a)
        sut.recordActive(b)
        sut.recordActive(a)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.first, a.directory)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.count, 2)
    }

    // MARK: - openWorkspace (real DB I/O)

    func testOpenWorkspaceCreatesDatabaseFile() throws {
        let dir = tempRoot.appending(path: "Alpha")
        let workspace = try sut.openWorkspace(at: dir)
        XCTAssertEqual(sut.active, workspace)
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: workspace.databaseFileURL.path(percentEncoded: false)),
            "Database file should be created on openWorkspace"
        )
    }

    func testOpenWorkspaceSetsDatabaseCurrent() throws {
        let dir = tempRoot.appending(path: "Beta")
        try sut.openWorkspace(at: dir)
        XCTAssertEqual(
            Database.current.workspaceDirectory,
            dir.canonicalDirectoryURL,
            "Database.current should point at the just-opened workspace"
        )
    }

    func testOpenWorkspaceRecordsBookkeeping() throws {
        let dir = tempRoot.appending(path: "Gamma")
        try sut.openWorkspace(at: dir)
        XCTAssertEqual(workspaceDefaults.lastOpenedWorkspace, dir.canonicalDirectoryURL)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.first, dir.canonicalDirectoryURL)
    }

    // MARK: - Observable recentWorkspaces

    func testRecentWorkspacesInitiallyMatchesDefaults() {
        // Pre-seed defaults, then build a new coordinator; recents should reflect.
        workspaceDefaults.pushRecent(URL(filePath: "/tmp/Pre1"))
        workspaceDefaults.pushRecent(URL(filePath: "/tmp/Pre2"))
        let coordinator = WorkspaceCoordinator(defaults: workspaceDefaults)
        XCTAssertEqual(coordinator.recentWorkspaces.count, 2)
        XCTAssertEqual(coordinator.recentWorkspaces.first?.lastPathComponent, "Pre2")
    }

    func testRecordActiveUpdatesObservedRecents() {
        XCTAssertTrue(sut.recentWorkspaces.isEmpty)
        sut.recordActive(Workspace(directory: URL(filePath: "/tmp/Tech")))
        XCTAssertEqual(sut.recentWorkspaces.count, 1)
        XCTAssertEqual(sut.recentWorkspaces.first?.lastPathComponent, "Tech")
    }

    func testRemoveRecentUpdatesObservedList() {
        sut.recordActive(Workspace(directory: URL(filePath: "/tmp/A")))
        sut.recordActive(Workspace(directory: URL(filePath: "/tmp/B")))
        sut.removeRecent(URL(filePath: "/tmp/A"))
        XCTAssertEqual(sut.recentWorkspaces.count, 1)
        XCTAssertEqual(sut.recentWorkspaces.first?.lastPathComponent, "B")
    }
}
