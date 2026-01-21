import SwiftUI
#if os(macOS)
import AppKit
#endif

struct MainView: View {
    @State private var viewModel = MainViewModel()
    @State private var showingClearAllConfirmation = false
    @State private var showingStatistics = false
    @State private var isExporting = false
    @State private var exportError: String?
    @State private var exportSuccess: String?
    @Environment(\.scenePhase) private var scenePhase
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    var body: some View {
        NavigationStack {
            List {
                allArticlesSection
                graphRAGSection
                hypergraphSection
                addFeedSection
                sourcesSection
            }
            .navigationTitle("NewsComb")
            .navigationDestination(for: SourceMetric.self) { metric in
                FeedItemsView(sourceId: metric.id, sourceName: metric.sourceName)
            }
            .navigationDestination(for: String.self) { destination in
                switch destination {
                case "all":
                    FeedItemsView()
                case "graphrag":
                    GraphRAGView()
                default:
                    EmptyView()
                }
            }
            .navigationDestination(for: QueryHistoryItem.self) { item in
                AnswerDetailView(response: item.toGraphRAGResponse())
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

                ToolbarItem(placement: .primaryAction) {
                    if viewModel.isProcessingHypergraph {
                        Button("Stop", systemImage: "stop.fill", role: .destructive) {
                            viewModel.cancelHypergraphProcessing()
                        }
                        .help("Stop knowledge graph processing")
                    } else {
                        Button {
                            Task {
                                await viewModel.processUnprocessedArticles()
                            }
                        } label: {
                            Label("Process Knowledge Graph", systemImage: "brain")
                        }
                        .disabled(viewModel.isRefreshing || viewModel.metrics.isEmpty)
                        .help("Extract knowledge graphs from article content using AI")
                    }
                }

                ToolbarItem(placement: .primaryAction) {
                    if viewModel.isSimplifyingGraph {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text(viewModel.simplifyProgress)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Button("Simplify Graph", systemImage: "arrow.triangle.merge") {
                            Task {
                                await viewModel.simplifyGraph()
                            }
                        }
                        .disabled(!viewModel.canSimplifyGraph() || viewModel.isRefreshing)
                        .help("Merge similar nodes in the knowledge graph")
                    }
                }

                #if os(macOS)
                ToolbarItem(placement: .primaryAction) {
                    Button("View Graph", systemImage: "chart.dots.scatter") {
                        openWindow(id: "graph-visualization")
                    }
                    .disabled(viewModel.hypergraphStats == nil || (viewModel.hypergraphStats?.nodeCount ?? 0) == 0)
                    .help("Open interactive graph visualization")
                }
                #endif

                ToolbarItem(placement: .primaryAction) {
                    Button("Statistics", systemImage: "chart.bar.fill") {
                        showingStatistics = true
                    }
                    .help("View feed and article statistics")
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
                viewModel.loadHypergraphStats()
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
                if viewModel.metrics.isEmpty && !viewModel.isRefreshing && viewModel.newSourceURL.isEmpty {
                    ContentUnavailableView(
                        "No RSS Sources",
                        systemImage: "newspaper",
                        description: Text("Add RSS feed URLs above to get started.")
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
            .sheet(isPresented: $showingStatistics) {
                StatisticsSheet(viewModel: viewModel)
            }
        }
    }

    // MARK: - Statistics Sheet

    private struct StatisticsSheet: View {
        let viewModel: MainViewModel
        @Environment(\.dismiss) private var dismiss

        var body: some View {
            NavigationStack {
                List {
                    feedStatisticsSection
                    articleStatisticsSection
                    if viewModel.hypergraphStats != nil {
                        knowledgeGraphSection
                    }
                    lastRefreshSection
                }
                .navigationTitle("Statistics")
                #if os(macOS)
                .frame(minWidth: 350, minHeight: 400)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") {
                            dismiss()
                        }
                    }
                }
            }
        }

        private var feedStatisticsSection: some View {
            Section {
                LabeledContent("Total Feeds", value: "\(viewModel.metrics.count)")
                LabeledContent("Active Feeds", value: "\(viewModel.nonEmptyFeedsCount)")
                LabeledContent("Empty Feeds", value: "\(viewModel.metrics.count - viewModel.nonEmptyFeedsCount)")
            } header: {
                Label("Feeds", systemImage: "antenna.radiowaves.left.and.right")
            }
        }

        private var articleStatisticsSection: some View {
            Section {
                LabeledContent("Total Articles", value: "\(viewModel.totalArticlesCount)")
                if viewModel.nonEmptyFeedsCount > 0 {
                    let average = viewModel.totalArticlesCount / viewModel.nonEmptyFeedsCount
                    LabeledContent("Average per Feed", value: "\(average)")
                }
            } header: {
                Label("Articles", systemImage: "doc.text.fill")
            }
        }

        private var knowledgeGraphSection: some View {
            Section {
                if let stats = viewModel.hypergraphStats {
                    LabeledContent("Concepts (Nodes)", value: "\(stats.nodeCount)")
                    LabeledContent("Relationships (Edges)", value: "\(stats.edgeCount)")
                }
            } header: {
                Label("Knowledge Graph", systemImage: "brain.head.profile")
            }
        }

        private var lastRefreshSection: some View {
            Section {
                if let lastRefresh = viewModel.lastRefreshTime {
                    LabeledContent("Last Refresh") {
                        Text(lastRefresh, format: .dateTime)
                    }
                    if viewModel.newArticlesFromLastRefresh > 0 {
                        LabeledContent("New Articles") {
                            Text("\(viewModel.newArticlesFromLastRefresh)")
                                .foregroundStyle(.green)
                        }
                    } else {
                        LabeledContent("New Articles", value: "0")
                    }
                } else {
                    Text("No refresh performed yet")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Label("Last Refresh", systemImage: "arrow.clockwise")
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

                        if viewModel.totalArticlesCount > 0 {
                            Text("\(viewModel.totalArticlesCount) articles from \(viewModel.nonEmptyFeedsCount) feed\(viewModel.nonEmptyFeedsCount == 1 ? "" : "s")")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        } else {
                            Text("No articles yet")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                } icon: {
                    Image(systemName: "doc.text.fill")
                        .foregroundStyle(.blue)
                }
            }

            // Show new articles indicator after refresh
            if viewModel.newArticlesFromLastRefresh > 0 {
                HStack {
                    Image(systemName: "sparkles")
                        .foregroundStyle(.green)
                    Text("\(viewModel.newArticlesFromLastRefresh) new article\(viewModel.newArticlesFromLastRefresh == 1 ? "" : "s") from last refresh")
                        .font(.caption)
                        .foregroundStyle(.green)
                }
            }
        }
    }

    @ViewBuilder
    private var graphRAGSection: some View {
        if viewModel.hypergraphStats != nil && (viewModel.hypergraphStats?.nodeCount ?? 0) > 0 {
            Section {
                NavigationLink(value: "graphrag") {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Ask Your News")
                                .font(.headline)
                            Text("Query your knowledge graph")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "text.bubble.fill")
                            .foregroundStyle(.purple)
                    }
                }
            } header: {
                Text("Knowledge Query")
            }
        }
    }

    @ViewBuilder
    private var hypergraphSection: some View {
        if viewModel.isProcessingHypergraph || viewModel.hypergraphStats != nil {
            Section {
                if viewModel.isProcessingHypergraph {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            ProgressView()
                                .controlSize(.small)
                            Text("Processing Knowledge Graph")
                                .font(.headline)
                            Spacer()
                            Button("Stop", systemImage: "stop.fill", role: .destructive) {
                                viewModel.cancelHypergraphProcessing()
                            }
                            .buttonStyle(.borderless)
                            .controlSize(.small)
                        }

                        if viewModel.hypergraphProgress.total > 0 {
                            ProgressView(
                                value: Double(viewModel.hypergraphProgress.processed),
                                total: Double(viewModel.hypergraphProgress.total)
                            )

                            Text("\(viewModel.hypergraphProgress.processed)/\(viewModel.hypergraphProgress.total) articles")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Text(viewModel.hypergraphProcessingStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .padding(.vertical, 4)
                }

                if let stats = viewModel.hypergraphStats {
                    Label {
                        VStack(alignment: .leading) {
                            Text("Knowledge Graph")
                                .font(.headline)
                            Text("\(stats.nodeCount) concepts, \(stats.edgeCount) relationships")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.purple)
                    }
                }
            } header: {
                Text("Knowledge Extraction")
            }
        }
    }

    private var addFeedSection: some View {
        Section {
            HStack {
                TextField("RSS Feed URL", text: $viewModel.newSourceURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif

                Button("Add", systemImage: "plus") {
                    viewModel.addSource()
                }
                .disabled(viewModel.newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Paste from Clipboard", systemImage: "doc.on.clipboard") {
                pasteFromClipboard()
            }
        } header: {
            Text("Add RSS Feed")
        } footer: {
            Text("Add RSS feed URLs individually or paste multiple URLs (one per line or comma-separated).")
        }
    }

    private func pasteFromClipboard() {
        #if os(macOS)
        if let string = NSPasteboard.general.string(forType: .string) {
            viewModel.pasteMultipleSources(string)
        }
        #else
        if let string = UIPasteboard.general.string {
            viewModel.pasteMultipleSources(string)
        }
        #endif
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
                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                    Button("Delete", systemImage: "trash", role: .destructive) {
                        viewModel.deleteSource(sourceId: metric.id)
                    }
                }
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

                    Button("Clear Content", systemImage: "trash") {
                        viewModel.clearFeedContent(sourceId: metric.id)
                    }
                    .disabled(metric.status == .fetching)

                    Divider()

                    Button("Remove Feed", systemImage: "minus.circle", role: .destructive) {
                        viewModel.deleteSource(sourceId: metric.id)
                    }
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
