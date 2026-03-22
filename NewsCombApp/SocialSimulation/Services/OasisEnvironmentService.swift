import Foundation
import OSLog

/// Status of the OASIS Python package installation.
enum OasisStatus: Sendable, Equatable {
    case installed(version: String)
    case notInstalled
    case pythonNotFound
    case error(String)

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Handles Python/OASIS environment detection and validation for social simulations.
///
/// All subprocess calls use `@concurrent` to avoid blocking the main actor.
/// This service is designed as a lightweight utility — errors are diagnostic, not fatal.
final class OasisEnvironmentService: Sendable {
    private static let logger = Logger(subsystem: "com.newscomb", category: "OasisEnvironment")

    /// Minimum required Python version (major, minor).
    static let minimumPythonVersion = (major: 3, minor: 10)

    /// Finds the best Python 3 binary by checking common paths, conda, and `which`.
    @concurrent
    func detectPythonPath() async -> String? {
        let home = FileManager.default.homeDirectoryForCurrentUser.path()

        // Static candidates + user-specific conda/miniconda/anaconda paths
        let candidates = [
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "\(home)/miniconda3/bin/python3",
            "\(home)/anaconda3/bin/python3",
            "\(home)/miniforge3/bin/python3",
            "\(home)/.pyenv/shims/python3",
            "/opt/local/bin/python3",
            "/usr/bin/python3",
        ]

        // Check candidates
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                if await validatePythonVersion(path) {
                    Self.logger.info("Detected Python at: \(path, privacy: .public)")
                    return path
                }
            }
        }

        // Check conda environments for a suitable Python
        let condaDirs = [
            "\(home)/miniconda3/envs",
            "\(home)/anaconda3/envs",
            "\(home)/miniforge3/envs",
        ]
        for condaDir in condaDirs {
            if let envNames = try? FileManager.default.contentsOfDirectory(atPath: condaDir) {
                for envName in envNames {
                    let envPython = "\(condaDir)/\(envName)/bin/python3"
                    if FileManager.default.isExecutableFile(atPath: envPython) {
                        if await validatePythonVersion(envPython) {
                            Self.logger.info("Detected Python in conda env '\(envName, privacy: .public)': \(envPython, privacy: .public)")
                            return envPython
                        }
                    }
                }
            }
        }

        // Fall back to `which python3` (may not work in sandboxed apps)
        if let path = runWhich("python3"), await validatePythonVersion(path) {
            Self.logger.info("Detected Python via which: \(path, privacy: .public)")
            return path
        }

        Self.logger.warning("No suitable Python \(Self.minimumPythonVersion.major).\(Self.minimumPythonVersion.minor)+ installation found")
        return nil
    }

    /// Runs `which` to find a binary, returning the path or nil.
    private func runWhich(_ binary: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [binary]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
               !path.isEmpty,
               FileManager.default.isExecutableFile(atPath: path) {
                return path
            }
        } catch {
            Self.logger.debug("which \(binary) failed: \(error.localizedDescription, privacy: .public)")
        }
        return nil
    }

    /// Validates that the Python binary at the given path meets the minimum version requirement.
    @concurrent
    func validatePythonVersion(_ pythonPath: String) async -> Bool {
        await parsePythonVersion(pythonPath) != nil
    }

    /// Parses the Python version from a binary, returning (major, minor) if valid.
    @concurrent
    func parsePythonVersion(_ pythonPath: String) async -> (major: Int, minor: Int)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return nil }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return nil }

            return Self.parseVersionString(output)
        } catch {
            Self.logger.debug("Failed to get Python version at \(pythonPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Parses a "Python X.Y.Z" version string into (major, minor), validating against the minimum.
    /// Exposed as static for testability.
    static func parseVersionString(_ output: String) -> (major: Int, minor: Int)? {
        let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacing("Python ", with: "")
            .split(separator: ".")

        guard components.count >= 2,
              let major = Int(components[0]),
              let minor = Int(components[1]) else {
            return nil
        }

        let valid = major > minimumPythonVersion.major ||
            (major == minimumPythonVersion.major && minor >= minimumPythonVersion.minor)

        if !valid {
            logger.info("Python \(major).\(minor) — requires \(minimumPythonVersion.major).\(minimumPythonVersion.minor)+")
            return nil
        }

        return (major, minor)
    }

    /// Checks whether the OASIS package is installed and returns its version.
    @concurrent
    func checkOasisInstalled(pythonPath: String) async -> OasisStatus {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            return .pythonNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "import oasis; print(oasis.__version__)"]
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        do {
            try process.run()
            process.waitUntilExit()

            if process.terminationStatus == 0 {
                let data = outPipe.fileHandleForReading.readDataToEndOfFile()
                let version = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
                Self.logger.info("OASIS installed: v\(version, privacy: .public)")
                return .installed(version: version)
            } else {
                let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
                let errMsg = String(data: errData, encoding: .utf8) ?? ""
                if errMsg.localizedStandardContains("ModuleNotFoundError") || errMsg.localizedStandardContains("No module named") {
                    Self.logger.info("OASIS not installed")
                    return .notInstalled
                }
                Self.logger.warning("OASIS check error: \(errMsg, privacy: .public)")
                return .error(errMsg.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        } catch {
            Self.logger.error("Failed to check OASIS: \(error.localizedDescription, privacy: .public)")
            return .error(error.localizedDescription)
        }
    }

    /// Returns the simulations directory within app support, creating it if needed.
    func simulationsDirectory() throws -> URL {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appending(path: "NewsComb").appending(path: "simulations")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
