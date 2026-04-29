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

    /// Most-recently-used workspaces, reflected from `WorkspaceDefaults`. Mutated
    /// here so SwiftUI views observing the coordinator see updates after
    /// `recordActive(_:)` / `switchWorkspace(to:)` push to the recents list.
    private(set) var recentWorkspaces: [URL] = []

    /// Set when `bootstrap()` failed to open an explicit-source workspace
    /// (CLI arg or env var). `ContentView` observes this and presents an
    /// alert so the user knows their explicit input was rejected, rather
    /// than the failure being silently logged. `nil` when no error is pending.
    private(set) var bootstrapError: BootstrapErrorState?

    private let logger = Logger(subsystem: "com.newscomb.app", category: "WorkspaceCoordinator")
    private let defaults: WorkspaceDefaults
    private let busyReasonsProvider: @MainActor () -> [String]

    init(
        defaults: WorkspaceDefaults = .shared,
        busyReasonsProvider: @escaping @MainActor () -> [String] = WorkspaceCoordinator.defaultBusyReasons
    ) {
        self.defaults = defaults
        self.busyReasonsProvider = busyReasonsProvider
        self.recentWorkspaces = defaults.recentWorkspaces
    }

    /// Removes a workspace from the recents list (e.g., the user deleted the
    /// directory). Forwards to `WorkspaceDefaults` and refreshes the observed list.
    func removeRecent(_ url: URL) {
        defaults.removeRecent(url)
        recentWorkspaces = defaults.recentWorkspaces
    }

    // MARK: - Bootstrap error surfacing

    /// Snapshot of a bootstrap failure suitable for SwiftUI presentation.
    /// Equatable + Sendable so SwiftUI can diff it across renders.
    struct BootstrapErrorState: Equatable, Sendable {
        let directory: URL
        let source: BootstrapSource
        let message: String
    }

    /// Stores a failure produced by `bootstrap()` so the UI can present it.
    func recordBootstrapError(_ error: BootstrapError) {
        bootstrapError = BootstrapErrorState(
            directory: error.directory,
            source: error.source,
            message: error.underlying.localizedDescription
        )
        logger.error(
            "Recorded bootstrap error for \(error.directory.path(percentEncoded: false), privacy: .public): \(error.underlying.localizedDescription, privacy: .public)"
        )
    }

    /// Clears any pending bootstrap error — typically called when the user
    /// dismisses the alert presented by `ContentView`.
    func clearBootstrapError() {
        bootstrapError = nil
    }

    /// Reasons the app currently can't accept a workspace switch. Empty when safe.
    /// Reads observed VM state — SwiftUI views observing this re-render when
    /// the underlying flags change.
    var busyReasons: [String] {
        busyReasonsProvider()
    }

    var canSwitchWorkspace: Bool {
        busyReasons.isEmpty
    }

    /// Production busy-reasons provider. Inspects shared view models for
    /// in-flight long-running operations.
    @MainActor
    static func defaultBusyReasons() -> [String] {
        var reasons: [String] = []
        let main = MainViewModel.shared
        if main.isProcessingHypergraph { reasons.append("processing knowledge graph") }
        if main.isRefreshing { reasons.append("refreshing feeds") }
        if main.isImportingOPML { reasons.append("importing OPML") }
        if main.isResettingGraph { reasons.append("resetting knowledge graph") }
        if main.isSimplifyingGraph { reasons.append("simplifying graph") }
        if main.isClassifying { reasons.append("classifying nodes") }
        return reasons
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
        recentWorkspaces = defaults.recentWorkspaces
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

    /// Wraps an explicit-source bootstrap failure with the URL the user named,
    /// so the UI alert can show *which* path was rejected rather than just an
    /// opaque error string. Only thrown for `--workspace` / `NEWSCOMB_WORKSPACE`
    /// — implicit sources continue to log + fall through.
    struct BootstrapError: Error, LocalizedError {
        let directory: URL
        let source: BootstrapSource
        let underlying: Error

        var errorDescription: String? {
            "Failed to open workspace at \(directory.path(percentEncoded: false)): \(underlying.localizedDescription)"
        }
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

        // 1. CLI argument — explicit, errors propagate (wrapped so the UI knows which path)
        if let path = Self.parseWorkspaceArg(from: commandLineArgs) {
            let url = URL(filePath: path).canonicalDirectoryURL
            do {
                let workspace = try openWorkspace(at: url)
                return .opened(workspace, source: .commandLine(url))
            } catch {
                throw BootstrapError(directory: url, source: .commandLine(url), underlying: error)
            }
        }

        // 2. Environment variable — explicit, errors propagate (wrapped)
        if let path = environment["NEWSCOMB_WORKSPACE"], !path.isEmpty {
            let url = URL(filePath: path).canonicalDirectoryURL
            do {
                let workspace = try openWorkspace(at: url)
                return .opened(workspace, source: .environment(url))
            } catch {
                throw BootstrapError(directory: url, source: .environment(url), underlying: error)
            }
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

    // MARK: - Settings copy

    /// Setting keys that describe **schema state on disk** rather than user
    /// intent. These must NOT be copied between workspaces — copying them
    /// would lie about the target's actual schema, breaking dimension-change
    /// detection in `Database.migrate`.
    ///
    /// Currently just `active_embedding_dimension`, which records the dim the
    /// vec0 virtual tables were last created with. Copying it would cause
    /// `createVec0Tables` to think no rebuild is needed even when the
    /// `embedding_dimension` setting was carried over from a workspace using
    /// a different size. Leaving it untouched lets the next migration detect
    /// the mismatch and rebuild the vec0 tables to match the user's intent.
    private static let nonPortableSettingKeys: Set<String> = [
        AppSettings.activeEmbeddingDimension
    ]

    /// Copies every portable row in the source workspace's `app_settings`
    /// table into the target workspace's `app_settings` table (UPSERT by key).
    /// Used when the user creates a new workspace and wants their LLM keys,
    /// model selections, prompts, and algorithm parameters carried over
    /// instead of reset to defaults.
    ///
    /// Both databases are opened transiently; `Database.current` is unchanged.
    /// The target's migration runs (creating tables and seeding defaults)
    /// before the upsert, so any new defaults the source's DB doesn't know
    /// about are preserved.
    ///
    /// Schema-state keys (see `nonPortableSettingKeys`) are skipped so the
    /// target's existing vec0-table dimension tracking remains accurate.
    /// On first use, if the copied `embedding_dimension` differs from the
    /// target's seed-default, `Database.migrate` detects the mismatch and
    /// rebuilds the vec0 tables — putting settings and schema in agreement.
    func copyAppSettings(from source: URL, to target: URL) throws {
        let sourceDB = try Database(directory: source)
        let targetDB = try Database(directory: target)

        let allRows = try sourceDB.dbQueue.read { db in
            try AppSettings.fetchAll(db)
        }
        let portable = allRows.filter { !Self.nonPortableSettingKeys.contains($0.key) }
        let skipped = allRows.count - portable.count

        try targetDB.dbQueue.write { db in
            for setting in portable {
                try db.execute(
                    sql: """
                        INSERT INTO app_settings (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [setting.key, setting.value]
                )
            }
        }

        logger.notice(
            "Copied \(portable.count, privacy: .public) app_settings rows (skipped \(skipped, privacy: .public) non-portable) from \(source.path(percentEncoded: false), privacy: .public) to \(target.path(percentEncoded: false), privacy: .public)"
        )
    }

    /// Convenience: copies from the currently-active workspace to `target`.
    /// Returns `true` if a copy actually happened, `false` if there was no
    /// active workspace or `target` was already the active workspace.
    @discardableResult
    func copyAppSettingsFromCurrent(to target: URL) throws -> Bool {
        guard let active else { return false }
        let canonicalTarget = target.canonicalDirectoryURL
        guard active.directory != canonicalTarget else { return false }
        try copyAppSettings(from: active.directory, to: canonicalTarget)
        return true
    }

    /// Provisions a new workspace from the currently-active one for the
    /// **File → New Workspace…** flow.
    ///
    /// Copies portable app settings from the active workspace (LLM keys,
    /// model selections, prompts, algorithm parameters) into the target.
    /// The new workspace starts with an empty `rss_source` table — the user
    /// picks feeds appropriate to the new domain via Settings → Feed Settings,
    /// where a "Seed Default Tech Feeds" button is also available as a
    /// shortcut.
    ///
    /// Returns `true` if provisioning happened, `false` if there was no
    /// active workspace or `target` already equals the active workspace.
    @discardableResult
    func provisionNewWorkspace(at target: URL) throws -> Bool {
        guard let active else { return false }
        let canonicalTarget = target.canonicalDirectoryURL
        guard active.directory != canonicalTarget else { return false }

        try copyAppSettings(from: active.directory, to: canonicalTarget)

        logger.notice(
            "Provisioned new workspace at \(canonicalTarget.path(percentEncoded: false), privacy: .public): copied settings, no feeds seeded"
        )
        return true
    }

    // MARK: - Switching

    enum SwitchError: Error, LocalizedError, Equatable {
        case busy(reasons: [String])

        var errorDescription: String? {
            switch self {
            case .busy(let reasons):
                return "Cannot switch workspace while busy: " + reasons.joined(separator: ", ")
            }
        }
    }

    /// Validates that no long-running jobs are in flight, then persists the
    /// target directory as the last-opened workspace (so a relaunch resolves it
    /// via Phase 3's bootstrap flow).
    ///
    /// **Does not relaunch the app** — that's the caller's responsibility. For
    /// v1, the File-menu / Settings UI relaunches via `NSApplication`. This
    /// keeps the coordinator decoupled from AppKit and gives every workspace a
    /// fresh process state without complex tear-down inside the running app.
    @discardableResult
    func switchWorkspace(to directory: URL) throws -> Workspace {
        let reasons = busyReasons
        if !reasons.isEmpty {
            logger.notice("Switch refused — busy: \(reasons.joined(separator: ", "), privacy: .public)")
            throw SwitchError.busy(reasons: reasons)
        }
        let target = Workspace(directory: directory)
        defaults.lastOpenedWorkspace = target.directory
        defaults.pushRecent(target.directory)
        recentWorkspaces = defaults.recentWorkspaces
        logger.notice("Switch staged to '\(target.directory.path(percentEncoded: false), privacy: .public)' — caller must relaunch")
        return target
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
