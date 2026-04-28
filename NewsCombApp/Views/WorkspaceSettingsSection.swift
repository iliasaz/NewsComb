#if os(macOS)
import AppKit
import SwiftUI

/// Settings pane section showing the active workspace and offering switch /
/// reveal-in-Finder. Drop-in for `SettingsView`'s `Form`.
struct WorkspaceSettingsSection: View {

    @Bindable var coordinator: WorkspaceCoordinator

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
                    Spacer()
                    Button("Switch Workspace…", systemImage: "rectangle.2.swap") {
                        switchWorkspace()
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

    private func switchWorkspace() {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = true
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Choose a workspace folder."
        panel.prompt = "Open Workspace"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            _ = try coordinator.switchWorkspace(to: url)
            let alert = NSAlert()
            alert.messageText = "Relaunch NewsComb?"
            alert.informativeText = "NewsComb will quit and reopen with the workspace at:\n\n\(url.path(percentEncoded: false))"
            alert.alertStyle = .informational
            alert.addButton(withTitle: "Relaunch")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn {
                WorkspaceRelauncher.relaunchApp()
            }
        } catch let error as WorkspaceCoordinator.SwitchError {
            let alert = NSAlert()
            alert.messageText = "Cannot switch workspace"
            alert.informativeText = error.errorDescription ?? "Unknown error"
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Switch failed"
            alert.informativeText = error.localizedDescription
            alert.alertStyle = .warning
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}
#endif
