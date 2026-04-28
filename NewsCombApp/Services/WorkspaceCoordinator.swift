import Foundation
import Observation
import OSLog

/// Owns the currently-active `Workspace` and the live `Database` instance for
/// that workspace. The single source of truth for "which knowledge base is the
/// app working with right now."
///
/// **Phase 2 (this file):** opens the Database when a workspace becomes active.
/// `openWorkspace(at:)` is the canonical entry point.
///
/// **Phase 3:** `bootstrap(...)` resolves the active workspace from CLI args /
/// env / `WorkspaceDefaults` / legacy migration / first-run picker, then calls
/// `openWorkspace(at:)`.
///
/// **Phase 4:** `switchWorkspace(to:)` adds refuse-while-busy semantics and
/// MainViewModel rebuild on top of `openWorkspace(at:)`.
@MainActor
@Observable
final class WorkspaceCoordinator {

    /// Production singleton. Tests should construct their own coordinator
    /// via `init()` to keep state isolated.
    static let shared = WorkspaceCoordinator()

    /// The currently-active workspace. `nil` until `openWorkspace(at:)` succeeds.
    private(set) var active: Workspace?

    private let logger = Logger(subsystem: "com.newscomb.app", category: "WorkspaceCoordinator")
    private let defaults: WorkspaceDefaults

    init(defaults: WorkspaceDefaults = .shared) {
        self.defaults = defaults
    }

    /// Opens (or creates) the workspace rooted at `directory`: builds the
    /// `Database`, runs migrations, marks it active, persists last-opened, and
    /// updates the recents list.
    ///
    /// Phase 4 will guard this with refuse-while-busy and rebuild MainViewModel.
    @discardableResult
    func openWorkspace(at directory: URL) throws -> Workspace {
        let workspace = Workspace(directory: directory)
        let database = try Database(directory: workspace.directory)
        Database.setCurrent(database)
        recordActive(workspace)
        return workspace
    }

    /// Records `workspace` as active and updates persistent state. Internal so
    /// tests can drive it without spinning up a real SQLite DB.
    func recordActive(_ workspace: Workspace) {
        active = workspace
        defaults.lastOpenedWorkspace = workspace.directory
        defaults.pushRecent(workspace.directory)
        logger.notice("Active workspace: \(workspace.directory.path(percentEncoded: false), privacy: .public)")
    }

    // MARK: - Bootstrap

    /// Where the bootstrapped workspace came from. Useful for diagnostics + UI
    /// (e.g. surfacing "opened from --workspace flag" in the about dialog).
    enum BootstrapSource: Equatable, Sendable {
        case commandLine(URL)
        case environment(URL)
        case lastOpened(URL)
        case legacy(URL)
    }

    enum BootstrapResult: Sendable {
        case opened(Workspace, source: BootstrapSource)
        /// No workspace could be found; the UI should show a first-run picker.
        case needsSelection
    }

    /// Resolves the active workspace at app launch. Resolution order:
    /// 1. `--workspace <path>` CLI argument.
    /// 2. `NEWSCOMB_WORKSPACE` environment variable.
    /// 3. `WorkspaceDefaults.lastOpenedWorkspace` (if the directory still exists).
    /// 4. Legacy `~/Library/Application Support/NewsComb/newscomb.sqlite` (if present).
    /// 5. Returns `.needsSelection` — UI displays the first-run picker.
    ///
    /// **Explicit sources (CLI, env) propagate errors** — bad user input should
    /// fail loudly. **Implicit sources log + fall through** — a deleted recent
    /// workspace should not block the app from launching.
    @discardableResult
    func bootstrap(
        commandLineArgs: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        legacyDirectory: URL = Workspace.legacyDirectory,
        fileManager: FileManager = .default
    ) throws -> BootstrapResult {

        // 1. CLI argument — explicit, errors propagate
        if let path = Self.parseWorkspaceArg(from: commandLineArgs) {
            let url = URL(filePath: path).canonicalDirectoryURL
            let workspace = try openWorkspace(at: url)
            return .opened(workspace, source: .commandLine(url))
        }

        // 2. Environment variable — explicit, errors propagate
        if let path = environment["NEWSCOMB_WORKSPACE"], !path.isEmpty {
            let url = URL(filePath: path).canonicalDirectoryURL
            let workspace = try openWorkspace(at: url)
            return .opened(workspace, source: .environment(url))
        }

        // 3. Last opened — implicit, errors logged + fall through
        if let url = defaults.lastOpenedWorkspace,
           fileManager.fileExists(atPath: url.path(percentEncoded: false)) {
            do {
                let workspace = try openWorkspace(at: url)
                return .opened(workspace, source: .lastOpened(url))
            } catch {
                logger.error("Failed to open last-opened workspace at \(url.path(percentEncoded: false), privacy: .public): \(error.localizedDescription, privacy: .public)")
            }
        }

        // 4. Legacy DB — implicit, errors logged + fall through
        let legacyDB = legacyDirectory.appending(path: Workspace.databaseFileName)
        if fileManager.fileExists(atPath: legacyDB.path(percentEncoded: false)) {
            do {
                let workspace = try openWorkspace(at: legacyDirectory)
                return .opened(workspace, source: .legacy(legacyDirectory.canonicalDirectoryURL))
            } catch {
                logger.error("Failed to open legacy workspace: \(error.localizedDescription, privacy: .public)")
            }
        }

        // 5. Nothing found — UI must show a first-run picker
        return .needsSelection
    }

    /// Extracts `<path>` from `--workspace <path>` or `--workspace=<path>`.
    /// Returns `nil` if the flag isn't present or has no following value.
    static func parseWorkspaceArg(from args: [String]) -> String? {
        var iterator = args.makeIterator()
        while let arg = iterator.next() {
            if arg == "--workspace" {
                if let next = iterator.next(), !next.isEmpty {
                    return next
                }
                return nil
            }
            if arg.hasPrefix("--workspace=") {
                let value = String(arg.dropFirst("--workspace=".count))
                return value.isEmpty ? nil : value
            }
        }
        return nil
    }
}
