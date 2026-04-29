import Foundation

/// A NewsComb workspace — a directory on disk containing a `newscomb.sqlite`
/// database and any associated artifacts. Identified by the canonicalized
/// directory URL.
///
/// Pure value type, no I/O. Validation (does the directory exist? is it
/// writable? does it contain a valid DB?) is the coordinator's job.
struct Workspace: Identifiable, Equatable, Hashable, Sendable {

    static let databaseFileName = "newscomb.sqlite"

    /// Canonicalized directory containing this workspace's database.
    let directory: URL

    var id: URL { directory }

    /// Display name — the directory's last path component (e.g. `"Tech"`).
    var name: String { directory.lastPathComponent }

    /// Absolute path to the workspace's SQLite file.
    var databaseFileURL: URL {
        directory.appending(path: Workspace.databaseFileName)
    }

    init(directory: URL) {
        self.directory = directory.canonicalDirectoryURL
    }
}

extension URL {

    /// Canonicalizes a file URL representing a directory: standardizes (resolves
    /// `.` / `..`) and strips the trailing `/` so equality holds across the
    /// variants `/tmp/Foo` and `/tmp/Foo/`.
    var canonicalDirectoryURL: URL {
        let std = self.standardizedFileURL
        let path = std.path(percentEncoded: false)
        guard path.hasSuffix("/"), path != "/" else { return std }
        return URL(filePath: String(path.dropLast()))
    }
}

extension Workspace {

    /// Default location for newly-created workspaces:
    /// `~/Documents/NewsComb-Workspaces/`.
    static var defaultWorkspacesRoot: URL {
        URL.documentsDirectory.appending(path: "NewsComb-Workspaces")
    }

    /// Legacy single-DB location used before the workspace feature.
    /// `~/Library/Application Support/NewsComb/` containing `newscomb.sqlite`.
    /// Treated as the "Default" workspace on first launch after upgrade.
    static var legacyDirectory: URL {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appending(path: "NewsComb")
    }

    static var legacyWorkspace: Workspace {
        Workspace(directory: legacyDirectory)
    }
}
