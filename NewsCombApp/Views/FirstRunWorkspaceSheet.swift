#if os(macOS)
import AppKit
import SwiftUI

/// First-run sheet shown when bootstrap returns `.needsSelection` — neither a
/// CLI/env workspace, nor a remembered last-opened, nor a legacy DB exists.
/// Lets the user create or open a workspace before any UI demands data.
struct FirstRunWorkspaceSheet: View {

    @Bindable var coordinator: WorkspaceCoordinator
    let onChosen: (URL) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56))
                .foregroundStyle(.tint)

            Text("Welcome to NewsComb")
                .font(.title.bold())

            Text("A workspace is a folder containing the SQLite database for an independent knowledge base. Create a new one or open an existing folder to begin.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)

            VStack(spacing: 12) {
                Button {
                    pickFolder(create: true)
                } label: {
                    Label("Create New Workspace", systemImage: "plus.circle")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)

                Button {
                    pickFolder(create: false)
                } label: {
                    Label("Open Existing Workspace", systemImage: "folder")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
            }
            .frame(maxWidth: 320)

            if !coordinator.recentWorkspaces.isEmpty {
                Divider().frame(maxWidth: 320)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Recent")
                        .font(.subheadline.bold())
                        .foregroundStyle(.secondary)
                    ForEach(coordinator.recentWorkspaces.prefix(5), id: \.self) { url in
                        Button {
                            onChosen(url)
                            dismiss()
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(url.lastPathComponent)
                                Spacer()
                                Text(url.path(percentEncoded: false))
                                    .font(.caption)
                                    .foregroundStyle(.tertiary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .frame(maxWidth: 320)
            }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 480)
    }

    private func pickFolder(create: Bool) {
        let panel = NSOpenPanel()
        panel.canCreateDirectories = create
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = create
            ? "Choose a folder for the new NewsComb workspace."
            : "Choose an existing NewsComb workspace folder."
        panel.prompt = create ? "Use Folder" : "Open Workspace"
        if create, let documents = try? FileManager.default.url(
            for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false
        ) {
            panel.directoryURL = documents.appending(path: "NewsComb-Workspaces")
        }
        if panel.runModal() == .OK, let url = panel.url {
            onChosen(url)
            dismiss()
        }
    }
}
#endif
