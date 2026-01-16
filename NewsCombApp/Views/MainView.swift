import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MainView: View {
    @State private var viewModel = MainViewModel()
    @State private var showingClearAllConfirmation = false
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportSuccess: String?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationStack {
            List {
                allArticlesSection
                sourcesSection
            }
            .navigationTitle("NewsComb")
            .navigationDestination(for: SourceMetric.self) { metric in
                FeedItemsView(sourceId: metric.id, sourceName: metric.sourceName)
            }
            .navigationDestination(for: String.self) { destination in
                if destination == "all" {
                    FeedItemsView()
                }
            }
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button("Refresh", systemImage: "arrow.clockwise") {
                        Task {
                            await viewModel.refreshFeeds()
                        }
                    }
                    .disabled(viewModel.isRefreshing)
                }

                ToolbarItem(placement: .primaryAction) {
                    Button {
                        Task {
                            await exportAll()
                        }
                    } label: {
                        if isExporting {
                            ProgressView()
                                .controlSize(.small)
                        } else {
                            Label("Export All", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isExporting || viewModel.isRefreshing || viewModel.metrics.isEmpty)
                }

                ToolbarItem(placement: .destructiveAction) {
                    Button("Clear All", systemImage: "trash") {
                        showingClearAllConfirmation = true
                    }
                    .disabled(viewModel.isRefreshing || viewModel.metrics.isEmpty)
                }
            }
            .confirmationDialog(
                "Clear All Articles",
                isPresented: $showingClearAllConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All Articles", role: .destructive) {
                    viewModel.clearAllArticles()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will delete all fetched articles from all feeds. Feed sources will be kept.")
            }
            .onAppear {
                viewModel.loadSources()
            }
            .onChange(of: scenePhase) { _, newPhase in
                if newPhase == .active {
                    viewModel.loadSources()
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeMainNotification)) { _ in
                viewModel.loadSources()
            }
            .overlay {
                if viewModel.metrics.isEmpty && !viewModel.isRefreshing {
                    ContentUnavailableView(
                        "No RSS Sources",
                        systemImage: "newspaper",
                        description: Text("Add RSS sources in Settings to get started.")
                    )
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
    }

    #if os(macOS)
    private func exportAll() async {
        isExporting = true
        defer { isExporting = false }

        let groupedArticles = viewModel.getAllArticlesGroupedBySource()
        guard !groupedArticles.isEmpty else {
            exportError = "No articles to export."
            return
        }

        guard let folderURL = await MarkdownExportService.showFolderPicker() else {
            return
        }

        // Create root folder: NewsComb-YYYY-MM-DD
        let dateString = MarkdownExportService.currentDateString()
        let rootFolderName = "NewsComb-\(dateString)"
        let rootFolderURL = folderURL.appending(path: rootFolderName)

        do {
            try MarkdownExportService.createDirectory(at: rootFolderURL)

            var totalExported = 0

            for (sourceName, articles) in groupedArticles {
                // Create folder for each source
                let sourceFolderName = MarkdownExportService.sanitizeFilename(sourceName)
                let sourceFolderURL = rootFolderURL.appending(path: sourceFolderName)
                try MarkdownExportService.createDirectory(at: sourceFolderURL)

                for article in articles {
                    let markdown = MarkdownExportService.articleToMarkdown(
                        title: article.title,
                        link: article.link,
                        author: article.author,
                        pubDate: article.pubDate,
                        sourceName: sourceName,
                        content: article.fullContent ?? article.rssDescription
                    )

                    let filename = MarkdownExportService.sanitizeFilename(article.title) + ".md"
                    let fileURL = sourceFolderURL.appending(path: filename)

                    try MarkdownExportService.writeToFile(content: markdown, at: fileURL)
                    totalExported += 1
                }
            }

            exportSuccess = "Exported \(totalExported) article\(totalExported == 1 ? "" : "s") from \(groupedArticles.count) source\(groupedArticles.count == 1 ? "" : "s") to \(rootFolderName)"
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }
    #else
    private func exportAll() async {
        // iOS implementation would go here
    }
    #endif

    private var allArticlesSection: some View {
        Section {
            NavigationLink(value: "all") {
                Label {
                    VStack(alignment: .leading) {
                        Text("All Articles")
                            .font(.headline)
                        Text("View all fetched articles")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.blue)
                }
            }
        }
    }

    private var sourcesSection: some View {
        Section {
            ForEach(viewModel.metrics) { metric in
                NavigationLink(value: metric) {
                    HStack {
                        VStack(alignment: .leading) {
                            Text(metric.sourceName)
                                .lineLimit(1)

                            statusText(for: metric.status)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        statusIcon(for: metric.status)
                    }
                }
                .disabled(metric.status == .fetching || metric.status == .pending)
                .contextMenu {
                    Button("Copy URL", systemImage: "doc.on.doc") {
                        #if os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(metric.sourceURL, forType: .string)
                        #endif
                    }

                    Divider()

                    Button("Refresh Feed", systemImage: "arrow.clockwise") {
                        Task {
                            await viewModel.refreshSingleFeed(sourceId: metric.id)
                        }
                    }
                    .disabled(metric.status == .fetching)

                    Divider()

                    Button("Clear & Reload", systemImage: "arrow.triangle.2.circlepath") {
                        viewModel.clearFeedContent(sourceId: metric.id)
                        Task {
                            await viewModel.refreshSingleFeed(sourceId: metric.id)
                        }
                    }
                    .disabled(metric.status == .fetching)

                    Button("Clear Content", systemImage: "trash", role: .destructive) {
                        viewModel.clearFeedContent(sourceId: metric.id)
                    }
                    .disabled(metric.status == .fetching)
                }
            }
        } header: {
            if !viewModel.metrics.isEmpty {
                Text("Feed Sources")
            }
        } footer: {
            if viewModel.totalItemsFetched > 0 {
                Text("Total items fetched: \(viewModel.totalItemsFetched)")
            }
        }
    }

    @ViewBuilder
    private func statusText(for status: FetchStatus) -> some View {
        switch status {
        case .pending:
            Text("Pending")
        case .fetching:
            Text("Fetching...")
        case .done(let count):
            Text("\(count) items")
        case .error(let message):
            Text(message)
                .foregroundStyle(.red)
        }
    }

    @ViewBuilder
    private func statusIcon(for status: FetchStatus) -> some View {
        switch status {
        case .pending:
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
        case .fetching:
            ProgressView()
        case .done:
            Image(systemName: "chevron.right")
                .foregroundStyle(.secondary)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    MainView()
}
