#if os(macOS)
import AppKit
import Foundation
import OSLog

/// Quits and relaunches the running NewsComb app. Used after a workspace
/// switch so the new workspace is bootstrapped from a fresh process.
///
/// The relaunch is performed by spawning a short-lived `/bin/sh` that waits
/// for the current process to terminate, then runs `open <bundle>`. This is
/// the standard macOS app-relaunch pattern — NSApplication has no built-in
/// "relaunch" because the process must outlive itself.
enum WorkspaceRelauncher {

    private static let logger = Logger(subsystem: "com.newscomb.app", category: "WorkspaceRelauncher")

    static func relaunchApp() {
        let bundlePath = Bundle.main.bundlePath
        let task = Process()
        task.executableURL = URL(filePath: "/bin/sh")
        // Quote the bundle path defensively — macOS app paths may contain spaces.
        task.arguments = ["-c", "sleep 0.4 && open \"\(bundlePath)\""]
        do {
            try task.run()
        } catch {
            logger.error("Failed to spawn relaunch helper: \(error.localizedDescription, privacy: .public)")
        }
        NSApplication.shared.terminate(nil)
    }
}
#endif
