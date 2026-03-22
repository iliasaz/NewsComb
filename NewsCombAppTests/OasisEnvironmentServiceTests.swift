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

    func testParseVersionString_valid314() {
        let result = OasisEnvironmentService.parseVersionString("Python 3.14.0")
        XCTAssertNotNil(result, "Python 3.14 should be accepted")
        XCTAssertEqual(result?.major, 3)
        XCTAssertEqual(result?.minor, 14)
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

    // MARK: - Candidate Path Construction

    func testHomePath_noTrailingSlash() {
        let homePath = OasisEnvironmentService.homePath()
        XCTAssertFalse(homePath.hasSuffix("/"), "homePath should not end with /: \(homePath)")
        XCTAssertTrue(homePath.hasPrefix("/"), "homePath should start with /: \(homePath)")

        // Verify path construction doesn't create double slashes
        let condaPath = "\(homePath)/miniconda3/bin/python3"
        XCTAssertFalse(condaPath.contains("//"), "Constructed path should not have //: \(condaPath)")
    }

    // MARK: - Live Process Execution

    func testProcessExecution_pythonVersion() async throws {
        // Test that Process can actually execute and capture output
        // This verifies subprocess execution works in the test environment
        let knownPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "miniconda3/bin/python3").path(percentEncoded: false)
        ]

        var foundWorkingPython = false
        for pythonPath in knownPaths {
            guard FileManager.default.isExecutableFile(atPath: pythonPath) else { continue }

            let process = Process()
            process.executableURL = URL(fileURLWithPath: pythonPath)
            process.arguments = ["--version"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()

            do {
                try process.run()
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""

                XCTAssertTrue(output.contains("Python"), "Expected 'Python' in output: '\(output)'")
                XCTAssertEqual(process.terminationStatus, 0, "python3 --version should exit with 0")

                let parsed = OasisEnvironmentService.parseVersionString(output)
                XCTAssertNotNil(parsed, "Should parse version from: '\(output)'")

                foundWorkingPython = true
                break
            } catch {
                // This path doesn't work, try next
                continue
            }
        }

        XCTAssertTrue(foundWorkingPython, "Should find at least one working Python on this machine")
    }

    func testValidatePythonVersion_withRealPython() async {
        // Test the actual validatePythonVersion method with a real Python binary
        let service = OasisEnvironmentService()

        let knownPaths = [
            "/opt/homebrew/bin/python3",
            "/usr/bin/python3",
            FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "miniconda3/bin/python3").path(percentEncoded: false)
        ]

        for pythonPath in knownPaths {
            guard FileManager.default.isExecutableFile(atPath: pythonPath) else { continue }
            let valid = await service.validatePythonVersion(pythonPath)
            // At least one should be valid (we know this machine has Python 3.10+)
            if valid {
                return // test passes
            }
        }

        XCTFail("No Python binary passed version validation")
    }

    // MARK: - Full Detection Pipeline

    func testDetectPythonPath_findsSystemPython() async {
        let service = OasisEnvironmentService()
        let path = await service.detectPythonPath()
        XCTAssertNotNil(path, "Should find Python on this machine")

        if let path {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path),
                          "Detected path should be executable: \(path)")

            // Verify the detected Python actually works
            let version = await service.parsePythonVersion(path)
            XCTAssertNotNil(version, "Detected Python should have valid version")
            if let version {
                XCTAssertGreaterThanOrEqual(version.minor, 10,
                                           "Detected Python should be 3.10+, got 3.\(version.minor)")
            }
        }
    }

    func testDetectPythonPath_prefersOasisInstalled() async {
        // If oasis is installed on this machine, the detected Python should have it
        let service = OasisEnvironmentService()
        guard let path = await service.detectPythonPath() else {
            XCTFail("Python not found")
            return
        }

        let status = await service.checkOasisInstalled(pythonPath: path)
        // On this machine, oasis is installed — the detected Python should be the one with it
        if case .installed(let version) = status {
            XCTAssertFalse(version.isEmpty)
            // The path should be the miniconda one where oasis is installed
            XCTAssertTrue(path.contains("miniconda") || path.contains("anaconda") || path.contains("conda"),
                          "Expected conda Python for oasis, got: \(path)")
        }
    }

    func testCheckOasisInstalled_withDetectedPython() async {
        let service = OasisEnvironmentService()
        guard let pythonPath = await service.detectPythonPath() else {
            XCTFail("Python not found — cannot test OASIS check")
            return
        }

        let status = await service.checkOasisInstalled(pythonPath: pythonPath)
        switch status {
        case .installed(let version):
            XCTAssertFalse(version.isEmpty, "Version should not be empty")
        case .notInstalled:
            // Acceptable — oasis might not be installed on the detected Python
            break
        case .pythonNotFound:
            XCTFail("Python was just detected at \(pythonPath), should not get pythonNotFound")
        case .error(let msg):
            XCTFail("Unexpected error checking OASIS: \(msg)")
        }
    }

    func testCheckOasisInstalled_withInvalidPath() async {
        let service = OasisEnvironmentService()
        let status = await service.checkOasisInstalled(pythonPath: "/nonexistent/python3")
        XCTAssertEqual(status, .pythonNotFound)
    }

    // MARK: - SettingsViewModel Integration

    func testSettingsViewModel_checkOasisEnvironment() async {
        let viewModel = await SettingsViewModel()

        // Initial state
        await MainActor.run {
            XCTAssertTrue(viewModel.simPythonDetectedPath.isEmpty, "Should start empty")
            XCTAssertEqual(viewModel.simOasisStatusText, "Not checked")
            XCTAssertFalse(viewModel.simOasisInstalled)
        }

        // Run environment check
        await viewModel.checkOasisEnvironment()

        // After check, Python should be detected on this machine
        await MainActor.run {
            XCTAssertFalse(viewModel.simPythonDetectedPath.isEmpty,
                           "Should have detected Python path")
            XCTAssertNotEqual(viewModel.simPythonDetectedPath, "Not found",
                              "Should find Python, not 'Not found'")
            XCTAssertNotEqual(viewModel.simOasisStatusText, "Not checked",
                              "OASIS status should be updated after check")
            XCTAssertFalse(viewModel.isCheckingEnvironment,
                           "Should not be checking anymore")
        }
    }

    // MARK: - SimulationConfig DB Access

    func testLoadPersistedDefaults_doesNotCrash() {
        // This exercises the GRDB read pattern that previously crashed due to
        // leaking the db handle outside the closure. If the read is done
        // correctly inside the closure, this completes without a fatal error.
        let defaults = SimulationConfig.loadPersistedDefaults()
        XCTAssertGreaterThan(defaults.agentsPerHourMin, 0)
        XCTAssertGreaterThanOrEqual(defaults.agentsPerHourMax, defaults.agentsPerHourMin)
        XCTAssertGreaterThan(defaults.semaphoreLimit, 0)
    }

    func testLoadPersistedDefaults_returnsExpectedRange() {
        let defaults = SimulationConfig.loadPersistedDefaults()
        // Should return either persisted values or AppSettings defaults
        XCTAssertGreaterThanOrEqual(defaults.agentsPerHourMin, 1)
        XCTAssertLessThanOrEqual(defaults.agentsPerHourMax, 200)
        XCTAssertLessThanOrEqual(defaults.semaphoreLimit, 1024)
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
