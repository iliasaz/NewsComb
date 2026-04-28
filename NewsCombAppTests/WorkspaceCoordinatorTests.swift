import XCTest
@testable import NewsCombApp

@MainActor
final class WorkspaceCoordinatorTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var workspaceDefaults: WorkspaceDefaults!
    private var sut: WorkspaceCoordinator!

    override func setUp() async throws {
        try await super.setUp()
        suiteName = "newscomb.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        workspaceDefaults = WorkspaceDefaults(defaults: defaults)
        sut = WorkspaceCoordinator(defaults: workspaceDefaults)
    }

    override func tearDown() async throws {
        defaults.removePersistentDomain(forName: suiteName)
        sut = nil
        workspaceDefaults = nil
        defaults = nil
        suiteName = nil
        try await super.tearDown()
    }

    func testActiveIsNilOnInit() {
        XCTAssertNil(sut.active)
    }

    func testSetActiveStoresWorkspace() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Tech"))
        sut.setActive(workspace)
        XCTAssertEqual(sut.active, workspace)
    }

    func testSetActivePersistsLastOpened() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Tech"))
        sut.setActive(workspace)
        XCTAssertEqual(workspaceDefaults.lastOpenedWorkspace, workspace.directory)
    }

    func testSetActivePushesToRecents() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Tech"))
        sut.setActive(workspace)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.first, workspace.directory)
    }

    func testSetActiveTwiceMovesMostRecentToFront() {
        let a = Workspace(directory: URL(filePath: "/tmp/A"))
        let b = Workspace(directory: URL(filePath: "/tmp/B"))
        sut.setActive(a)
        sut.setActive(b)
        sut.setActive(a)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.first, a.directory)
        XCTAssertEqual(workspaceDefaults.recentWorkspaces.count, 2)
    }
}
