import XCTest
@testable import NewsCombApp

final class WorkspaceDefaultsTests: XCTestCase {

    private var suiteName: String!
    private var defaults: UserDefaults!
    private var sut: WorkspaceDefaults!

    override func setUp() {
        super.setUp()
        suiteName = "newscomb.test.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)!
        sut = WorkspaceDefaults(defaults: defaults)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        sut = nil
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    // MARK: - lastOpenedWorkspace

    func testLastOpenedWorkspaceIsNilByDefault() {
        XCTAssertNil(sut.lastOpenedWorkspace)
    }

    func testLastOpenedWorkspaceRoundtrips() {
        let url = URL(filePath: "/tmp/Tech")
        sut.lastOpenedWorkspace = url
        XCTAssertEqual(sut.lastOpenedWorkspace, url.standardizedFileURL)
    }

    func testLastOpenedWorkspaceClearsOnNil() {
        sut.lastOpenedWorkspace = URL(filePath: "/tmp/Tech")
        sut.lastOpenedWorkspace = nil
        XCTAssertNil(sut.lastOpenedWorkspace)
    }

    // MARK: - recentWorkspaces

    func testRecentsEmptyByDefault() {
        XCTAssertTrue(sut.recentWorkspaces.isEmpty)
    }

    func testPushRecentInsertsAtFront() {
        sut.pushRecent(URL(filePath: "/tmp/A"))
        sut.pushRecent(URL(filePath: "/tmp/B"))
        let recents = sut.recentWorkspaces
        XCTAssertEqual(recents.count, 2)
        XCTAssertEqual(recents.first?.lastPathComponent, "B")
        XCTAssertEqual(recents.last?.lastPathComponent, "A")
    }

    func testPushRecentDeduplicates() {
        sut.pushRecent(URL(filePath: "/tmp/A"))
        sut.pushRecent(URL(filePath: "/tmp/B"))
        sut.pushRecent(URL(filePath: "/tmp/A"))
        let recents = sut.recentWorkspaces
        XCTAssertEqual(recents.count, 2)
        XCTAssertEqual(recents.first?.lastPathComponent, "A")
        XCTAssertEqual(recents.last?.lastPathComponent, "B")
    }

    func testPushRecentDeduplicatesIgnoringTrailingSlash() {
        sut.pushRecent(URL(filePath: "/tmp/A"))
        sut.pushRecent(URL(filePath: "/tmp/A/"))
        XCTAssertEqual(sut.recentWorkspaces.count, 1)
    }

    func testPushRecentCapsAtMax() {
        for i in 0..<(WorkspaceDefaults.maxRecents + 5) {
            sut.pushRecent(URL(filePath: "/tmp/W\(i)"))
        }
        let recents = sut.recentWorkspaces
        XCTAssertEqual(recents.count, WorkspaceDefaults.maxRecents)
        // Most recent push should be at the front
        XCTAssertEqual(
            recents.first?.lastPathComponent,
            "W\(WorkspaceDefaults.maxRecents + 4)"
        )
    }

    func testRemoveRecent() {
        sut.pushRecent(URL(filePath: "/tmp/A"))
        sut.pushRecent(URL(filePath: "/tmp/B"))
        sut.removeRecent(URL(filePath: "/tmp/A"))
        XCTAssertEqual(sut.recentWorkspaces.count, 1)
        XCTAssertEqual(sut.recentWorkspaces.first?.lastPathComponent, "B")
    }
}
