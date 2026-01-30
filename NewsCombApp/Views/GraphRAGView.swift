import SwiftUI

/// View for querying the knowledge graph using natural language.
struct GraphRAGView: View {
    @State private var viewModel = GraphRAGViewModel()
    @FocusState private var isQueryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            queryInputSection

            Divider()

            emptyStateSection
        }
        .navigationTitle("Ask Your News")
        .navigationDestination(item: Binding<LiveQueryNavigation?>(
            get: { viewModel.pendingLiveQuery },
            set: { viewModel.pendingLiveQuery = $0 }
        )) { liveQuery in
            AnswerDetailView(liveQuery: liveQuery)
        }
        .onAppear {
            viewModel.loadHistory()
        }
        .onChange(of: viewModel.pendingLiveQuery) { _, newValue in
            if newValue == nil {
                // Returning from answer view — refresh history to include newly saved items
                viewModel.loadHistory()
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

    // MARK: - Query Input

    private var queryInputSection: some View {
        VStack(spacing: 12) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)

                TextField("Ask about your news...", text: $viewModel.queryText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...4)
                    .focused($isQueryFieldFocused)
                    .onSubmit {
                        viewModel.submitQuery()
                    }

                if !viewModel.queryText.isEmpty {
                    Button("Clear", systemImage: "xmark.circle.fill") {
                        viewModel.clearQuery()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(12)
            .background(.background.secondary)
            .clipShape(.rect(cornerRadius: 10))

            HStack {
                Button {
                    viewModel.submitQuery()
                } label: {
                    Text("Ask")
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.queryText.isEmpty)

                Spacer()

                if let stats = viewModel.getStatistics() {
                    Text("\(stats.nodeCount) concepts, \(stats.edgeCount) relationships")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding()
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        ScrollView {
            VStack(spacing: 20) {
                if !viewModel.isConfigured() {
                    configurationWarning
                } else {
                    helpSection
                }

                if !viewModel.persistedHistory.isEmpty {
                    historySection
                }
            }
            .padding()
        }
    }

    private var configurationWarning: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)

            Text("LLM Not Configured")
                .font(.headline)

            Text("Configure an LLM provider in Settings to use the knowledge graph query feature.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding()
        .frame(maxWidth: .infinity)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12))
    }

    private var helpSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Try asking:")
                .font(.headline)

            ForEach(GraphRAGViewModel.sampleQueries, id: \.self) { query in
                Button {
                    viewModel.queryText = query
                    isQueryFieldFocused = true
                } label: {
                    HStack {
                        Image(systemName: "lightbulb")
                            .foregroundStyle(.yellow)
                        Text(query)
                            .foregroundStyle(.primary)
                            .font(.subheadline)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Question History")
                    .font(.headline)
                Spacer()
                Button("Clear", role: .destructive) {
                    viewModel.clearHistory()
                }
                .font(.caption)
            }

            ScrollView {
                LazyVStack(spacing: 6) {
                    ForEach(viewModel.persistedHistory) { item in
                        NavigationLink(value: item) {
                            HStack {
                                Image(systemName: "clock.arrow.circlepath")
                                    .foregroundStyle(.secondary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(item.query)
                                        .lineLimit(1)
                                        .foregroundStyle(.primary)
                                        .font(.subheadline)
                                    Text(item.answer)
                                        .lineLimit(1)
                                        .foregroundStyle(.secondary)
                                        .font(.caption)
                                }
                                Spacer()
                                Text(item.createdAt, style: .relative)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                                Image(systemName: "chevron.right")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 8)
                            .background(.background.secondary)
                            .clipShape(.rect(cornerRadius: 8))
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(maxHeight: 250)
        }
    }
}

#Preview {
    NavigationStack {
        GraphRAGView()
    }
}
