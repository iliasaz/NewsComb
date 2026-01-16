import SwiftUI
#if os(macOS)
import AppKit
#endif

struct FeedItemsView: View {
    @State private var viewModel = FeedItemsViewModel()
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportSuccess: String?
    let sourceId: Int64?
    let sourceName: String?

    init(sourceId: Int64? = nil, sourceName: String? = nil) {
        self.sourceId = sourceId
        self.sourceName = sourceName
    }

    var body: some View {
        List {
            ForEach(viewModel.filteredItems) { item in
                NavigationLink(value: item) {
                    FeedItemRow(item: item)
                }
                .contextMenu {
                    Button("Copy Link", systemImage: "doc.on.doc") {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(item.link, forType: .string)
                        #endif
                    }

                    if let url = URL(string: item.link) {
                        Divider()
                        Link(destination: url) {
                            Label("Open in Browser", systemImage: "safari")
                        }
                    }
                }
            }
        }
        .navigationTitle(sourceName ?? "All Articles")
        .navigationDestination(for: FeedItemDisplay.self) { item in
            FeedItemDetailView(item: item)
        }
        .searchable(text: $viewModel.searchText, prompt: "Search articles")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    Task {
                        await exportFeed()
                    }
                } label: {
                    if isExporting {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Label("Export Feed", systemImage: "square.and.arrow.down")
                    }
                }
                .disabled(isExporting || viewModel.filteredItems.isEmpty)
            }
        }
        .refreshable {
            await viewModel.refresh()
        }
        .overlay {
            if viewModel.isLoading && viewModel.items.isEmpty {
                ProgressView("Loading articles...")
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(
                    "No Articles",
                    systemImage: "doc.text",
                    description: Text("Refresh feeds to fetch new articles.")
                )
            }
        }
        .onAppear {
            if let sourceId {
                viewModel.loadItems(forSourceId: sourceId)
            } else {
                viewModel.loadItems()
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
        .alert("Export Error", isPresented: .init(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK") { exportError = nil }
        } message: {
            if let error = exportError {
                Text(error)
            }
        }
        .alert("Export Complete", isPresented: .init(
            get: { exportSuccess != nil },
            set: { if !$0 { exportSuccess = nil } }
        )) {
            Button("OK") { exportSuccess = nil }
        } message: {
            if let message = exportSuccess {
                Text(message)
            }
        }
    }

    #if os(macOS)
    private func exportFeed() async {
        isExporting = true
        defer { isExporting = false }

        let itemsToExport = viewModel.filteredItems
        guard !itemsToExport.isEmpty else {
            exportError = "No articles to export."
            return
        }

        guard let folderURL = await MarkdownExportService.showFolderPicker() else {
            return
        }

        // Create folder with feed name and date
        let feedName = MarkdownExportService.sanitizeFilename(sourceName ?? "All Articles")
        let dateString = MarkdownExportService.currentDateString()
        let exportFolderName = "\(feedName)-\(dateString)"
        let exportFolderURL = folderURL.appending(path: exportFolderName)

        do {
            try MarkdownExportService.createDirectory(at: exportFolderURL)

            var exportedCount = 0
            for item in itemsToExport {
                let markdown = MarkdownExportService.articleToMarkdown(
                    title: item.title,
                    link: item.link,
                    author: item.author,
                    pubDate: item.pubDate,
                    sourceName: item.sourceName,
                    content: item.fullContent ?? item.rssDescription
                )

                let filename = MarkdownExportService.sanitizeFilename(item.title) + ".md"
                let fileURL = exportFolderURL.appending(path: filename)

                try MarkdownExportService.writeToFile(content: markdown, at: fileURL)
                exportedCount += 1
            }

            exportSuccess = "Exported \(exportedCount) article\(exportedCount == 1 ? "" : "s") to \(exportFolderName)"
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }
    #else
    private func exportFeed() async {
        // iOS implementation would go here
    }
    #endif
}

struct FeedItemRow: View {
    let item: FeedItemDisplay

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(item.sourceName)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                if !item.displayDate.isEmpty {
                    Text(item.displayDate)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Text(item.title)
                .font(.headline)
                .lineLimit(2)

            if !item.snippet.isEmpty {
                Text(item.snippet)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                if let author = item.author, !author.isEmpty {
                    Label(author, systemImage: "person")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Spacer()

                if item.hasFullContent {
                    Label("Full article", systemImage: "doc.text.fill")
                        .font(.caption2)
                        .foregroundStyle(.blue)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

#Preview {
    NavigationStack {
        FeedItemsView()
    }
}
