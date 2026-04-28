import XCTest
@testable import NewsCombApp

final class WorkspaceTests: XCTestCase {

    func testInitCanonicalizesDirectory() {
        let raw = URL(filePath: "/tmp/./foo/../foo/")
        let workspace = Workspace(directory: raw)
        XCTAssertEqual(workspace.directory.path(percentEncoded: false), "/tmp/foo")
    }

    func testNameIsLastPathComponent() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Workspaces/Tech"))
        XCTAssertEqual(workspace.name, "Tech")
    }

    func testDatabaseFileURLAppendsCorrectFilename() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Workspaces/Tech"))
        XCTAssertEqual(
            workspace.databaseFileURL.path(percentEncoded: false),
            "/tmp/Workspaces/Tech/newscomb.sqlite"
        )
    }

    func testEqualityIgnoresTrailingSlash() {
        let a = Workspace(directory: URL(filePath: "/tmp/Tech"))
        let b = Workspace(directory: URL(filePath: "/tmp/Tech/"))
        XCTAssertEqual(a, b)
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testIdentityIsDirectory() {
        let workspace = Workspace(directory: URL(filePath: "/tmp/Tech"))
        XCTAssertEqual(workspace.id, workspace.directory)
    }

    func testLegacyDirectoryPointsAtAppSupport() {
        let legacy = Workspace.legacyDirectory.path(percentEncoded: false)
        XCTAssertTrue(
            legacy.contains("Application Support/NewsComb"),
            "Expected legacy directory under Application Support, got: \(legacy)"
        )
    }

    func testDefaultWorkspacesRootIsUnderDocuments() {
        let root = Workspace.defaultWorkspacesRoot.path(percentEncoded: false)
        XCTAssertTrue(
            root.contains("Documents/NewsComb-Workspaces"),
            "Expected default root under Documents, got: \(root)"
        )
    }
}
