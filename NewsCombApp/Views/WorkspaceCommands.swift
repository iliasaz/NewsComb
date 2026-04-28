#if os(macOS)
import AppKit
import OSLog
import SwiftUI

/// File-menu commands for managing workspaces. Wires into the main `WindowGroup`
/// via `.commands { WorkspaceCommands(coordinator: ...) }`.
struct WorkspaceCommands: Commands {

    @Bindable var coordinator: WorkspaceCoordinator

    private static let logger = Logger(subsystem: "com.newscomb.app", category: "WorkspaceCommands")

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("New Workspace…") {
                handleNewWorkspace()
            }
            .keyboardShortcut("n", modifiers: [.shift, .command])

            Button("Open Workspace…") {
                handleOpenWorkspace()
            }
            .keyboardShortcut("o", modifiers: [.shift, .command])

            Menu("Open Recent Workspace") {
                ForEach(coordinator.recentWorkspaces, id: \.self) { url in
                    Button(url.lastPathComponent) {
                        attemptSwitch(to: url)
                    }
                }
                if !coordinator.recentWorkspaces.isEmpty {
                    Divider()
                    Button("Clear Menu") {
                        for url in coordinator.recentWorkspaces {
                            coordinator.removeRecent(url)
                        }
                    }
                }
            }
            .disabled(coordinator.recentWorkspaces.isEmpty)

            Divider()

            Button("Reveal Workspace in Finder") {
                if let dir = coordinator.active?.directory {
                    NSWorkspace.shared.activateFileViewerSelecting([dir])
                }
            }
            .disabled(coordinator.active == nil)

            Divider()
        }
    }

    // MARK: - Actions

    private func handleNewWorkspace() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder for the new NewsComb workspace. The folder may be empty or contain an existing newscomb.sqlite."
        panel.prompt = "Use Folder"
        if panel.runModal() == .OK, let url = panel.url {
            attemptSwitch(to: url)
        }
    }

    private func handleOpenWorkspace() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = false
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a folder containing a NewsComb workspace."
        panel.prompt = "Open Workspace"
        if panel.runModal() == .OK, let url = panel.url {
            attemptSwitch(to: url)
        }
    }

    private func attemptSwitch(to url: URL) {
        do {
            _ = try coordinator.switchWorkspace(to: url)
            confirmAndRelaunch(to: url)
        } catch let error as WorkspaceCoordinator.SwitchError {
            showError(
                title: "Cannot switch workspace",
                message: error.errorDescription ?? "Unknown error"
            )
        } catch {
            showError(
                title: "Switch failed",
                message: error.localizedDescription
            )
        }
    }

    private func confirmAndRelaunch(to url: URL) {
        let alert = NSAlert()
        alert.messageText = "Relaunch NewsComb?"
        alert.informativeText = "NewsComb will quit and reopen with the workspace at:\n\n\(url.path(percentEncoded: false))"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Cancel")
        if alert.runModal() == .alertFirstButtonReturn {
            Self.logger.notice("User confirmed relaunch for workspace at \(url.path(percentEncoded: false), privacy: .public)")
            WorkspaceRelauncher.relaunchApp()
        }
    }

    private func showError(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
