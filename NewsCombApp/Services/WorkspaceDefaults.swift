import Foundation
import OSLog

/// App-global settings stored in `UserDefaults`. These persist across workspace
/// switches and survive deletion of any individual workspace.
///
/// Workspace-scoped settings (LLM model, embedding dimension, etc.) live in
/// each workspace's `app_settings` SQLite table — not here.
struct WorkspaceDefaults: @unchecked Sendable {

    static let maxRecents = 10

    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.newscomb.app", category: "WorkspaceDefaults")

    /// Production singleton backed by `UserDefaults.standard`.
    static let shared = WorkspaceDefaults(defaults: .standard)

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    // MARK: - Keys

    private enum Key {
        static let lastOpened = "newscomb.workspace.lastOpened"
        static let recents = "newscomb.workspace.recents"
    }

    // MARK: - Last-opened workspace

    var lastOpenedWorkspace: URL? {
        get {
            guard let path = defaults.string(forKey: Key.lastOpened) else { return nil }
            return URL(filePath: path).canonicalDirectoryURL
        }
        nonmutating set {
            if let url = newValue {
                defaults.set(url.canonicalDirectoryURL.path(percentEncoded: false), forKey: Key.lastOpened)
            } else {
                defaults.removeObject(forKey: Key.lastOpened)
            }
        }
    }

    // MARK: - Recent workspaces (most-recent first, capped at `maxRecents`)

    var recentWorkspaces: [URL] {
        get {
            let paths = defaults.stringArray(forKey: Key.recents) ?? []
            return paths.map { URL(filePath: $0).canonicalDirectoryURL }
        }
        nonmutating set {
            let paths = newValue.map { $0.canonicalDirectoryURL.path(percentEncoded: false) }
            defaults.set(paths, forKey: Key.recents)
        }
    }

    /// Pushes a workspace to the front of the recents list (deduplicated; capped at `maxRecents`).
    func pushRecent(_ url: URL) {
        let canonical = url.canonicalDirectoryURL
        var recents = recentWorkspaces
        recents.removeAll { $0 == canonical }
        recents.insert(canonical, at: 0)
        if recents.count > Self.maxRecents {
            recents = Array(recents.prefix(Self.maxRecents))
        }
        recentWorkspaces = recents
        logger.debug("Pushed recent workspace: \(canonical.path(percentEncoded: false), privacy: .public)")
    }

    /// Removes the workspace from recents (e.g. after the directory is deleted).
    func removeRecent(_ url: URL) {
        let canonical = url.canonicalDirectoryURL
        var recents = recentWorkspaces
        recents.removeAll { $0 == canonical }
        recentWorkspaces = recents
    }

    /// Test-only: clears all workspace-related defaults from the backing store.
    func resetForTesting() {
        defaults.removeObject(forKey: Key.lastOpened)
        defaults.removeObject(forKey: Key.recents)
    }
}
