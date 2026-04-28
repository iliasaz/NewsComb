import XCTest
@testable import NewsCombApp

@MainActor
final class WorkspaceCoordinatorBootstrapTests: XCTestCase {

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
            .appending(path: "BootstrapTests-\(UUID().uuidString)")
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

    // MARK: - parseWorkspaceArg

    func testParseWorkspaceArgWithSpaceForm() {
        let args = ["NewsCombApp", "--workspace", "/tmp/Tech"]
        XCTAssertEqual(WorkspaceCoordinator.parseWorkspaceArg(from: args), "/tmp/Tech")
    }

    func testParseWorkspaceArgWithEqualsForm() {
        let args = ["NewsCombApp", "--workspace=/tmp/Tech"]
        XCTAssertEqual(WorkspaceCoordinator.parseWorkspaceArg(from: args), "/tmp/Tech")
    }

    func testParseWorkspaceArgReturnsNilWhenAbsent() {
        let args = ["NewsCombApp", "--other-flag", "value"]
        XCTAssertNil(WorkspaceCoordinator.parseWorkspaceArg(from: args))
    }

    func testParseWorkspaceArgReturnsNilWhenSpaceFormHasNoValue() {
        let args = ["NewsCombApp", "--workspace"]
        XCTAssertNil(WorkspaceCoordinator.parseWorkspaceArg(from: args))
    }

    func testParseWorkspaceArgReturnsNilWhenEqualsFormIsEmpty() {
        let args = ["NewsCombApp", "--workspace="]
        XCTAssertNil(WorkspaceCoordinator.parseWorkspaceArg(from: args))
    }

    func testParseWorkspaceArgIgnoresArgsBefore() {
        let args = ["NewsCombApp", "-NSDocumentRevisionsDebugMode", "YES", "--workspace", "/tmp/Tech"]
        XCTAssertEqual(WorkspaceCoordinator.parseWorkspaceArg(from: args), "/tmp/Tech")
    }

    // MARK: - bootstrap resolution priority

    func testBootstrapFromCommandLine() throws {
        let dir = tempRoot.appending(path: "FromCLI")
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp", "--workspace", dir.path(percentEncoded: false)],
            environment: [:],
            legacyDirectory: tempRoot.appending(path: "fake-legacy")
        )
        guard case let .opened(workspace, source) = result else {
            return XCTFail("Expected .opened, got \(result)")
        }
        XCTAssertEqual(workspace.directory, dir.canonicalDirectoryURL)
        if case .commandLine = source { /* ok */ } else { XCTFail("Expected .commandLine source, got \(source)") }
    }

    func testBootstrapFromEnvironment() throws {
        let dir = tempRoot.appending(path: "FromEnv")
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp"],
            environment: ["NEWSCOMB_WORKSPACE": dir.path(percentEncoded: false)],
            legacyDirectory: tempRoot.appending(path: "fake-legacy")
        )
        guard case let .opened(workspace, source) = result else {
            return XCTFail("Expected .opened, got \(result)")
        }
        XCTAssertEqual(workspace.directory, dir.canonicalDirectoryURL)
        if case .environment = source { /* ok */ } else { XCTFail("Expected .environment source, got \(source)") }
    }

    func testCommandLineTakesPriorityOverEnvironment() throws {
        let cli = tempRoot.appending(path: "CLI")
        let env = tempRoot.appending(path: "Env")
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp", "--workspace", cli.path(percentEncoded: false)],
            environment: ["NEWSCOMB_WORKSPACE": env.path(percentEncoded: false)],
            legacyDirectory: tempRoot.appending(path: "fake-legacy")
        )
        guard case let .opened(workspace, _) = result else {
            return XCTFail("Expected .opened, got \(result)")
        }
        XCTAssertEqual(workspace.directory, cli.canonicalDirectoryURL)
    }

    func testEnvironmentTakesPriorityOverLastOpened() throws {
        let env = tempRoot.appending(path: "Env")
        let last = tempRoot.appending(path: "Last")
        try FileManager.default.createDirectory(at: last, withIntermediateDirectories: true)
        workspaceDefaults.lastOpenedWorkspace = last
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp"],
            environment: ["NEWSCOMB_WORKSPACE": env.path(percentEncoded: false)],
            legacyDirectory: tempRoot.appending(path: "fake-legacy")
        )
        guard case let .opened(workspace, _) = result else {
            return XCTFail("Expected .opened, got \(result)")
        }
        XCTAssertEqual(workspace.directory, env.canonicalDirectoryURL)
    }

    func testBootstrapFromLastOpened() throws {
        let dir = tempRoot.appending(path: "LastOpened")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        workspaceDefaults.lastOpenedWorkspace = dir
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp"],
            environment: [:],
            legacyDirectory: tempRoot.appending(path: "fake-legacy")
        )
        guard case let .opened(workspace, source) = result else {
            return XCTFail("Expected .opened, got \(result)")
        }
        XCTAssertEqual(workspace.directory, dir.canonicalDirectoryURL)
        if case .lastOpened = source { /* ok */ } else { XCTFail("Expected .lastOpened source, got \(source)") }
    }

    func testBootstrapFallsThroughWhenLastOpenedDirectoryMissing() throws {
        // Last-opened points at a directory that doesn't exist on disk.
        let missing = tempRoot.appending(path: "DoesNotExistOnDisk")
        workspaceDefaults.lastOpenedWorkspace = missing

        // No CLI, no env, no legacy → should return needsSelection.
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp"],
            environment: [:],
            legacyDirectory: tempRoot.appending(path: "fake-legacy")
        )
        guard case .needsSelection = result else {
            return XCTFail("Expected .needsSelection, got \(result)")
        }
    }

    func testBootstrapFromLegacy() throws {
        // Simulate the legacy DB by creating the directory + file.
        let fakeLegacyDir = tempRoot.appending(path: "fake-legacy")
        try FileManager.default.createDirectory(at: fakeLegacyDir, withIntermediateDirectories: true)
        let dbFile = fakeLegacyDir.appending(path: Workspace.databaseFileName)
        // openWorkspace will overwrite/migrate this; an empty placeholder is fine.
        try Data().write(to: dbFile)

        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp"],
            environment: [:],
            legacyDirectory: fakeLegacyDir
        )
        guard case let .opened(workspace, source) = result else {
            return XCTFail("Expected .opened, got \(result)")
        }
        XCTAssertEqual(workspace.directory, fakeLegacyDir.canonicalDirectoryURL)
        if case .legacy = source { /* ok */ } else { XCTFail("Expected .legacy source, got \(source)") }
    }

    func testBootstrapReturnsNeedsSelectionWhenNothingConfigured() throws {
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp"],
            environment: [:],
            legacyDirectory: tempRoot.appending(path: "fake-legacy-not-present")
        )
        guard case .needsSelection = result else {
            return XCTFail("Expected .needsSelection, got \(result)")
        }
        XCTAssertNil(sut.active)
    }

    func testBootstrapEmptyEnvironmentVarIsTreatedAsAbsent() throws {
        let result = try sut.bootstrap(
            commandLineArgs: ["NewsCombApp"],
            environment: ["NEWSCOMB_WORKSPACE": ""],
            legacyDirectory: tempRoot.appending(path: "fake-legacy")
        )
        guard case .needsSelection = result else {
            return XCTFail("Expected .needsSelection, got \(result)")
        }
    }
}
