import XCTest
@testable import NewsCombApp

final class OasisEnvironmentServiceTests: XCTestCase {

    // MARK: - Version String Parsing

    func testParseVersionString_valid310() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.10.13")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.major, 3)
        XCTAssertEqual(result?.minor, 10)
    }

    func testParseVersionString_valid311() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.11.0")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.major, 3)
        XCTAssertEqual(result?.minor, 11)
    }

    func testParseVersionString_valid312() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.12.1")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.major, 3)
        XCTAssertEqual(result?.minor, 12)
    }

    func testParseVersionString_valid313() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.13.0")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.major, 3)
        XCTAssertEqual(result?.minor, 13)
    }

    func testParseVersionString_tooOld39() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.9.7")
        XCTAssertNil(result, "Python 3.9 should be rejected (minimum is 3.10)")
    }

    func testParseVersionString_tooOld38() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.8.10")
        XCTAssertNil(result, "Python 3.8 should be rejected")
    }

    func testParseVersionString_python2() {
        let result = OasisEnvironmentService.parseVersionString("Python 2.7.18")
        XCTAssertNil(result, "Python 2.x should be rejected")
    }

    func testParseVersionString_withTrailingNewline() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.10.8\n")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.major, 3)
        XCTAssertEqual(result?.minor, 10)
    }

    func testParseVersionString_withTrailingWhitespace() {
        let result = OasisEnvironmentService.parseVersionString("  Python 3.11.2  \n")
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.major, 3)
        XCTAssertEqual(result?.minor, 11)
    }

    func testParseVersionString_emptyString() {
        let result = OasisEnvironmentService.parseVersionString("")
        XCTAssertNil(result)
    }

    func testParseVersionString_garbage() {
        let result = OasisEnvironmentService.parseVersionString("not a version")
        XCTAssertNil(result)
    }

    func testParseVersionString_onlyMajor() {
        let result = OasisEnvironmentService.parseVersionString("Python 3")
        XCTAssertNil(result, "Need at least major.minor")
    }

    // MARK: - OasisStatus

    func testOasisStatus_isInstalled() {
        XCTAssertTrue(OasisStatus.installed(version: "0.2.5").isInstalled)
        XCTAssertFalse(OasisStatus.notInstalled.isInstalled)
        XCTAssertFalse(OasisStatus.pythonNotFound.isInstalled)
        XCTAssertFalse(OasisStatus.error("something").isInstalled)
    }

    // MARK: - Live Detection (integration test, requires Python on the machine)

    func testDetectPythonPath_findsSystemPython() async {
        let service = OasisEnvironmentService()
        let path = await service.detectPythonPath()

        // This machine has Python installed, so detection should succeed
        XCTAssertNotNil(path, "Should find Python on this machine")

        if let path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path))
        }
    }

    func testCheckOasisInstalled_withDetectedPython() async {
        let service = OasisEnvironmentService()
        guard let pythonPath = await service.detectPythonPath() else {
            XCTFail("Python not found — cannot test OASIS check")
            return
        }

        let status = await service.checkOasisInstalled(pythonPath: pythonPath)
        // We know oasis is installed on this machine
        switch status {
        case .installed(let version):
            XCTAssertFalse(version.isEmpty, "Version should not be empty")
        case .notInstalled:
            // Acceptable if the detected Python doesn't have oasis
            break
        case .pythonNotFound:
            XCTFail("Python was just detected, should not get pythonNotFound")
        case .error(let msg):
            XCTFail("Unexpected error: \(msg)")
        }
    }

    func testCheckOasisInstalled_withInvalidPath() async {
        let service = OasisEnvironmentService()
        let status = await service.checkOasisInstalled(pythonPath: "/nonexistent/python3")
        XCTAssertEqual(status, .pythonNotFound)
    }

    // MARK: - Simulations Directory

    func testSimulationsDirectory_createsPath() throws {
        let service = OasisEnvironmentService()
        let dir = try service.simulationsDirectory()

        let dirPath = dir.path(percentEncoded: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dirPath), "Directory should exist at \(dirPath)")
        XCTAssertTrue(dirPath.contains("NewsComb/simulations"), "Path should contain NewsComb/simulations: \(dirPath)")
    }
}
