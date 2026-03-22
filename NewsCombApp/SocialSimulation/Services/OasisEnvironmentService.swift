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

    /// Finds the best Python 3 binary by checking common paths and `which`.
    @concurrent
    func detectPythonPath() async -> String? {
        let candidates = [
            "/usr/bin/python3",
            "/usr/local/bin/python3",
            "/opt/homebrew/bin/python3",
            "/opt/local/bin/python3",
        ]

        // Check candidates first
        for path in candidates {
            if FileManager.default.isExecutableFile(atPath: path) {
                if await validatePythonVersion(path) {
                    Self.logger.info("Detected Python at: \(path, privacy: .public)")
                    return path
                }
            }
        }

        // Fall back to `which python3`
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = ["python3"]
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
                if await validatePythonVersion(path) {
                    Self.logger.info("Detected Python via which: \(path, privacy: .public)")
                    return path
                }
            }
        } catch {
            Self.logger.warning("Failed to run 'which python3': \(error.localizedDescription, privacy: .public)")
        }

        Self.logger.warning("No suitable Python 3.11+ installation found")
        return nil
    }

    /// Validates that the Python binary at the given path is version 3.11 or later.
    @concurrent
    func validatePythonVersion(_ pythonPath: String) async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: pythonPath)
        process.arguments = ["--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()

            guard process.terminationStatus == 0 else { return false }

            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            guard let output = String(data: data, encoding: .utf8) else { return false }

            // Parse "Python 3.X.Y"
            let components = output.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacing("Python ", with: "")
                .split(separator: ".")

            guard components.count >= 2,
                  let major = Int(components[0]),
                  let minor = Int(components[1]) else {
                return false
            }

            let valid = major == 3 && minor >= 11
            if !valid {
                Self.logger.info("Python \(major).\(minor) found at \(pythonPath, privacy: .public) — requires 3.11+")
            }
            return valid
        } catch {
            Self.logger.debug("Failed to validate Python version at \(pythonPath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return false
        }
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
