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

    /// Finds the best Python 3 binary, preferring one that has OASIS installed.
    ///
    /// Strategy: collect all valid Python paths, then return the first one
    /// that has camel-oasis installed. If none have it, return the first valid Python.
    @concurrent
    func detectPythonPath() async -> String? {
        let homePath = Self.homePath()

        // All candidate paths to check, in preference order
        var candidates = [
            "\(homePath)/miniconda3/bin/python3",
            "\(homePath)/anaconda3/bin/python3",
            "\(homePath)/miniforge3/bin/python3",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
            "\(homePath)/.pyenv/shims/python3",
            "/opt/local/bin/python3",
            "/usr/bin/python3",
        ]

        // Also add conda environment Pythons
        let condaDirs = [
            "\(homePath)/miniconda3/envs",
            "\(homePath)/anaconda3/envs",
            "\(homePath)/miniforge3/envs",
        ]
        for condaDir in condaDirs {
            if let envNames = try? FileManager.default.contentsOfDirectory(atPath: condaDir) {
                for envName in envNames.sorted() {
                    candidates.append("\(condaDir)/\(envName)/bin/python3")
                }
            }
        }

        // Add `which python3` result
        if let whichPath = runWhich("python3") {
            if !candidates.contains(whichPath) {
                candidates.insert(whichPath, at: 0)
            }
        }

        // Collect all valid Python paths
        var validPythons: [String] = []
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                if await validatePythonVersion(path) {
                    validPythons.append(path)
                }
            }
        }

        guard !validPythons.isEmpty else {
            Self.logger.warning("No suitable Python \(Self.minimumPythonVersion.major).\(Self.minimumPythonVersion.minor)+ found")
            return nil
        }

        // Prefer the Python that has OASIS installed
        for path in validPythons {
            let status = await checkOasisInstalled(pythonPath: path)
            if status.isInstalled {
                Self.logger.info("Detected Python with OASIS at: \(path, privacy: .public)")
                return path
            }
        }

        // No Python has OASIS — return the first valid one
        let fallback = validPythons[0]
        Self.logger.info("Detected Python (no OASIS) at: \(fallback, privacy: .public)")
        return fallback
    }

    /// Returns the user's home directory path without trailing slash.
    static func homePath() -> String {
        let raw = FileManager.default.homeDirectoryForCurrentUser
            .path(percentEncoded: false)
        // Remove trailing slash to avoid double-slash in path construction
        if raw.hasSuffix("/") {
            return String(raw.dropLast())
        }
        return raw
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
    ///
    /// Uses `importlib.metadata` to check the package version without fully
    /// importing `oasis`, which avoids triggering import errors from
    /// dependency conflicts (e.g., sentence_transformers + PyTorch version mismatches).
    @concurrent
    func checkOasisInstalled(pythonPath: String) async -> OasisStatus {
        guard FileManager.default.isExecutableFile(atPath: pythonPath) else {
            return .pythonNotFound
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["-c", "import importlib.metadata; print(importlib.metadata.version('camel-oasis'))"]
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
                if errMsg.localizedStandardContains("ModuleNotFoundError")
                    || errMsg.localizedStandardContains("No module named")
                    || errMsg.localizedStandardContains("PackageNotFoundError") {
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
