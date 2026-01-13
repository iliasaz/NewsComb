import SwiftUI

struct MainView: View {
    @State private var viewModel = MainViewModel()

    var body: some View {
        NavigationStack {
            List {
                metricsSection
            }
            .navigationTitle("NewsComb")
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
            .overlay {
                if viewModel.metrics.isEmpty {
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

    private var metricsSection: some View {
        Section {
            ForEach(viewModel.metrics) { metric in
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
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
        }
    }
}

#Preview {
    MainView()
}
