import Foundation
import Observation
import OSLog

/// Owns the currently-active `Workspace` and (in later phases) the live
/// `Database` instance for that workspace. The single source of truth for
/// "which knowledge base is the app working with right now."
///
/// **Phase 1 (this file):** skeleton only — holds the active `Workspace`,
/// exposes `setActive(_:)`. No Database wiring, no switching, no validation.
///
/// **Phase 2:** adds the live `Database` instance to the active workspace.
///
/// **Phase 3:** `bootstrap(...)` resolves the active workspace from CLI args /
/// env / `WorkspaceDefaults` / legacy migration / first-run picker.
///
/// **Phase 4:** `switchTo(_:)` with refuse-while-busy semantics.
@MainActor
@Observable
final class WorkspaceCoordinator {

    /// Production singleton. Tests should construct their own coordinator
    /// via `init()` to keep state isolated.
    static let shared = WorkspaceCoordinator()

    /// The currently-active workspace. `nil` until `setActive(_:)` is called
    /// (Phase 3 wires this up at app launch).
    private(set) var active: Workspace?

    private let logger = Logger(subsystem: "com.newscomb.app", category: "WorkspaceCoordinator")
    private let defaults: WorkspaceDefaults

    init(defaults: WorkspaceDefaults = .shared) {
        self.defaults = defaults
    }

    /// Records the given workspace as active and updates the recents list.
    /// Phase 1 is the only state-change entry point; Phase 4 will route
    /// through this after refuse-while-busy and DB swap logic.
    func setActive(_ workspace: Workspace) {
        active = workspace
        defaults.lastOpenedWorkspace = workspace.directory
        defaults.pushRecent(workspace.directory)
        logger.notice("Active workspace set: \(workspace.directory.path(percentEncoded: false), privacy: .public)")
    }
}
