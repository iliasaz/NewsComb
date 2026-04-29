#if os(macOS)
import AppKit
import SwiftUI

/// Settings pane section showing the active workspace and offering switch /
/// reveal-in-Finder. Drop-in for `SettingsView`'s `Form`.
struct WorkspaceSettingsSection: View {

    @Bindable var coordinator: WorkspaceCoordinator

    private var isOnDefault: Bool {
        coordinator.active?.directory == Workspace.legacyDirectory.canonicalDirectoryURL
    }

    var body: some View {
        Section {
            if let active = coordinator.active {
                LabeledContent("Active Workspace") {
                    Text(active.name).bold()
                }
                LabeledContent("Path") {
                    Text(active.directory.path(percentEncoded: false))
                        .font(.callout.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack {
                    Button("Reveal in Finder", systemImage: "folder") {
                        NSWorkspace.shared.activateFileViewerSelecting([active.directory])
                    }
                    Button("Open Default Workspace", systemImage: "house") {
                        switchToDefault()
                    }
                    .disabled(isOnDefault || !coordinator.canSwitchWorkspace)
                    .help(
                        isOnDefault
                            ? "You're already using the default workspace at \(Workspace.legacyDirectory.path(percentEncoded: false))."
                            : "Switch to the legacy default workspace at \(Workspace.legacyDirectory.path(percentEncoded: false))."
                    )
                    Spacer()
                    Button("Switch Workspace…", systemImage: "rectangle.2.swap") {
                        switchToPickedFolder()
                    }
                    .disabled(!coordinator.canSwitchWorkspace)
                }
                if !coordinator.busyReasons.isEmpty {
                    Text("Switching is disabled while: \(coordinator.busyReasons.joined(separator: ", ")).")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledContent("Active Workspace") {
                    Text("none — open or create one from the File menu")
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Workspace")
        } footer: {
            Text("A workspace is a folder containing the SQLite database for an independent knowledge base. Switching workspaces relaunches NewsComb.")
        }
    }

    // MARK: - Actions

    private func switchToPickedFolder() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a workspace folder."
        panel.prompt = "Open Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attemptSwitch(to: url)
    }

    private func switchToDefault() {
        attemptSwitch(to: Workspace.legacyDirectory)
    }

    private func attemptSwitch(to url: URL) {
        do {
            _ = try coordinator.switchWorkspace(to: url)
            confirmAndRelaunch(to: url)
        } catch let error as WorkspaceCoordinator.SwitchError {
            showAlert(
                title: "Cannot switch workspace",
                message: error.errorDescription ?? "Unknown error",
                style: .warning
            )
        } catch {
            showAlert(
                title: "Switch failed",
                message: error.localizedDescription,
                style: .warning
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
            WorkspaceRelauncher.relaunchApp()
        }
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
#endif
