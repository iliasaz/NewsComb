import SwiftUI

struct MainView: View {
    @State private var viewModel = MainViewModel()
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
        }
    }

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
