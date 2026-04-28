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
}
