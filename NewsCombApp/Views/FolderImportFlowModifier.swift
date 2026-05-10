import SwiftUI
import UniformTypeIdentifiers

/// Bundles the three modifiers that drive the local-folder import flow:
/// the `.fileImporter` for picking a folder, the title-confirmation sheet,
/// and the result alert. Extracted into a `ViewModifier` so MainView's body
/// modifier chain stays under the SwiftUI type-checker's complexity budget.
struct FolderImportFlowModifier: ViewModifier {
    @Bindable var viewModel: MainViewModel
    @Binding var showingFolderPicker: Bool
    @Binding var showingImportTitleSheet: Bool
    @Binding var pendingImportFolder: URL?
    @Binding var importFeedTitle: String

    func body(content: Content) -> some View {
        content
            .fileImporter(
                isPresented: $showingFolderPicker,
                allowedContentTypes: [.folder]
            ) { result in
                switch result {
                case .success(let url):
                    pendingImportFolder = url
                    importFeedTitle = url.lastPathComponent
                    showingImportTitleSheet = true
                case .failure(let error):
                    viewModel.errorMessage = "Failed to open folder: \(error.localizedDescription)"
                }
            }
            .sheet(isPresented: $showingImportTitleSheet) {
                FolderImportTitleSheet(
                    folderURL: pendingImportFolder,
                    title: $importFeedTitle,
                    onConfirm: confirmImport,
                    onCancel: cancelImport
                )
            }
            .alert("Import Complete", isPresented: importResultBinding) {
                Button("OK") { viewModel.fileImportResult = nil }
            } message: {
                if let r = viewModel.fileImportResult {
                    Text(Self.resultMessage(r))
                }
            }
    }

    private var importResultBinding: Binding<Bool> {
        Binding(
            get: { viewModel.fileImportResult != nil },
            set: { if !$0 { viewModel.fileImportResult = nil } }
        )
    }

    private func confirmImport() {
        guard let url = pendingImportFolder else { return }
        let title = importFeedTitle
        showingImportTitleSheet = false
        Task {
            // Security-scoped access must wrap the entire recursive import —
            // every per-file read inside the enumerator inherits the parent
            // folder's scope on macOS sandboxed builds.
            let gotAccess = url.startAccessingSecurityScopedResource()
            defer { if gotAccess { url.stopAccessingSecurityScopedResource() } }
            await viewModel.importFolder(rootURL: url, feedTitle: title)
        }
    }

    private func cancelImport() {
        showingImportTitleSheet = false
        pendingImportFolder = nil
    }

    static func resultMessage(_ r: FileImportService.Outcome) -> String {
        var parts: [String] = []
        parts.append("Ingested \(r.ingested) file\(r.ingested == 1 ? "" : "s") into \"\(r.sourceTitle)\".")
        var skips: [String] = []
        if r.skippedTooShort > 0 { skips.append("\(r.skippedTooShort) too short") }
        if r.skippedUnreadable > 0 { skips.append("\(r.skippedUnreadable) unreadable") }
        if r.skippedTooLarge > 0 { skips.append("\(r.skippedTooLarge) too large") }
        if !skips.isEmpty {
            parts.append("Skipped: " + skips.joined(separator: ", ") + ".")
        }
        return parts.joined(separator: " ")
    }
}
