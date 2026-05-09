import SwiftUI

/// Lightweight sheet that appears after the user picks a folder for local
/// import. Lets the user confirm or rename the manual feed title before the
/// (potentially long) recursive import runs. The sheet is purely presentational
/// — it doesn't touch the database; the parent view's `onConfirm` callback
/// drives `MainViewModel.importFolder`.
struct FolderImportTitleSheet: View {
    let folderURL: URL?
    @Binding var title: String
    var onConfirm: () -> Void
    var onCancel: () -> Void

    @FocusState private var titleFieldFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Feed title", text: $title)
                        .focused($titleFieldFocused)
                        #if os(iOS)
                        .textInputAutocapitalization(.words)
                        #endif
                } header: {
                    Text("Feed title")
                } footer: {
                    Text("This will appear in the sources list. The folder's files are imported as articles inside this feed.")
                }

                if let folderURL {
                    Section {
                        LabeledContent("Folder") {
                            Text(folderURL.path)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .truncationMode(.middle)
                        }
                    }
                }
            }
            .navigationTitle("Import Local Files")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Import", action: onConfirm)
                        .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { titleFieldFocused = true }
        }
        .frame(minWidth: 420, minHeight: 220)
    }
}
