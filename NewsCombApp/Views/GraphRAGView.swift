import SwiftUI

/// View for querying the knowledge graph using natural language.
struct GraphRAGView: View {
    @State private var viewModel = GraphRAGViewModel()
    @FocusState private var isQueryFieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            queryInputSection

            Divider()

            if let response = viewModel.currentResponse {
                responseSection(response)
            } else if viewModel.isQuerying {
                loadingSection
            } else {
                emptyStateSection
            }
        }
        .navigationTitle("Ask Your News")
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
                        Task {
                            await viewModel.executeQuery()
                        }
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
                    Task {
                        await viewModel.executeQuery()
                    }
                } label: {
                    if viewModel.isQuerying {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Text("Ask")
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(viewModel.queryText.isEmpty || viewModel.isQuerying)

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

    // MARK: - Loading

    private var loadingSection: some View {
        VStack(spacing: 16) {
            ProgressView()
                .controlSize(.large)
            Text("Searching knowledge graph...")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Empty State

    private var emptyStateSection: some View {
        ScrollView {
            VStack(spacing: 24) {
                if !viewModel.isConfigured() {
                    configurationWarning
                } else {
                    helpSection
                }

                if !viewModel.queryHistory.isEmpty {
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
        VStack(alignment: .leading, spacing: 16) {
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
                        Spacer()
                    }
                    .padding(12)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var historySection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Questions")
                    .font(.headline)
                Spacer()
                Button("Clear", role: .destructive) {
                    viewModel.clearHistory()
                }
                .font(.caption)
            }

            ForEach(viewModel.queryHistory.prefix(5)) { response in
                Button {
                    viewModel.loadFromHistory(response)
                } label: {
                    HStack {
                        Image(systemName: "clock.arrow.circlepath")
                            .foregroundStyle(.secondary)
                        Text(response.query)
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                        Spacer()
                        Text(response.generatedAt, style: .relative)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(10)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 8))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Response Section

    private func responseSection(_ response: GraphRAGResponse) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                answerSection(response)

                if !response.relatedNodes.isEmpty {
                    relatedNodesSection(response.relatedNodes)
                }

                if !response.sourceArticles.isEmpty {
                    sourcesSection(response.sourceArticles)
                }
            }
            .padding()
        }
    }

    private func answerSection(_ response: GraphRAGResponse) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Answer", systemImage: "text.bubble")
                .font(.headline)

            Text(response.answer)
                .textSelection(.enabled)

            HStack {
                Text("Generated")
                Text(response.generatedAt, style: .relative)
                Text("ago")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12))
    }

    private func relatedNodesSection(_ nodes: [GraphRAGResponse.RelatedNode]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Related Concepts", systemImage: "brain.head.profile")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(nodes.prefix(15)) { node in
                    NodeChip(
                        label: node.label,
                        type: node.nodeType,
                        similarity: node.similarity
                    )
                }
            }
        }
    }

    private func sourcesSection(_ articles: [GraphRAGResponse.SourceArticle]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sources", systemImage: "doc.text")
                .font(.headline)

            ForEach(articles) { article in
                SourceArticleRow(article: article)
            }
        }
    }
}

// MARK: - Supporting Views

private struct NodeChip: View {
    let label: String
    let type: String?
    let similarity: Double

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .lineLimit(1)

            if let type {
                Text("(\(type))")
                    .foregroundStyle(.secondary)
                    .font(.caption2)
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(chipColor.opacity(0.2))
        .foregroundStyle(chipColor)
        .clipShape(.capsule)
    }

    private var chipColor: Color {
        if similarity > 0.9 {
            return .green
        } else if similarity > 0.8 {
            return .blue
        } else {
            return .secondary
        }
    }
}

private struct SourceArticleRow: View {
    let article: GraphRAGResponse.SourceArticle

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(article.title)
                    .font(.subheadline)
                    .bold()
                    .lineLimit(2)

                Spacer()

                if let pubDate = article.pubDate {
                    Text(pubDate, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !article.relevantChunks.isEmpty {
                ForEach(article.relevantChunks.prefix(2)) { chunk in
                    Text(chunk.content)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .padding(.leading, 8)
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(.blue.opacity(0.5))
                                .frame(width: 2)
                        }
                }
            }

            if let link = article.link, let url = URL(string: link) {
                Link(destination: url) {
                    Label("Open Article", systemImage: "arrow.up.right.square")
                        .font(.caption)
                }
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 8))
    }
}

/// A simple flow layout for wrapping chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)

        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.x, y: bounds.minY + placement.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> (size: CGSize, placements: [(x: CGFloat, y: CGFloat, size: CGSize)]) {
        let maxWidth = proposal.width ?? .infinity
        var placements: [(x: CGFloat, y: CGFloat, size: CGSize)] = []

        var currentX: CGFloat = 0
        var currentY: CGFloat = 0
        var lineHeight: CGFloat = 0
        var totalHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)

            if currentX + size.width > maxWidth && currentX > 0 {
                currentX = 0
                currentY += lineHeight + spacing
                lineHeight = 0
            }

            placements.append((x: currentX, y: currentY, size: size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return (CGSize(width: maxWidth, height: totalHeight), placements)
    }
}

#Preview {
    NavigationStack {
        GraphRAGView()
    }
}
