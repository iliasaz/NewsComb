import SwiftUI

/// View for displaying a saved question/answer from history.
struct AnswerDetailView: View {
    @State private var viewModel: AnswerDetailViewModel

    /// Creates the view with a query history item.
    init(historyItem: QueryHistoryItem) {
        _viewModel = State(initialValue: AnswerDetailViewModel(historyItem: historyItem))
    }

    private var response: GraphRAGResponse {
        viewModel.response
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                questionSection
                answerSection

                // Deep Analysis section
                deepAnalysisSection

                if !response.relatedNodes.isEmpty {
                    relatedNodesSection
                }

                if !response.reasoningPaths.isEmpty {
                    reasoningPathsSection
                }

                if !response.graphPaths.isEmpty {
                    graphPathsSection
                }

                if !response.sourceArticles.isEmpty {
                    sourcesSection
                }
            }
            .padding()
        }
        .navigationTitle("Answer")
    }

    // MARK: - Sections

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Question", systemImage: "questionmark.circle")
                .font(.headline)

            Text(response.query)
                .font(.body)
                .textSelection(.enabled)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12))
    }

    private var answerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Answer", systemImage: "text.bubble")
                .font(.headline)

            let markdown = try? AttributedString(
                markdown: response.answer,
                options: .init(
                    allowsExtendedAttributes: true,
                    interpretedSyntax: .inlineOnly,
                    failurePolicy: .returnPartiallyParsedIfPossible
                )
            )
            if let markdown {
                Text(markdown)
                    .textSelection(.enabled)
            } else {
                Text(response.answer)
                    .textSelection(.enabled)
            }

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

    private var relatedNodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Related Concepts", systemImage: "brain.head.profile")
                .font(.headline)

            FlowLayout(spacing: 8) {
                ForEach(response.relatedNodes.prefix(15)) { node in
                    NodeChip(
                        label: node.label,
                        type: node.nodeType,
                        similarity: node.similarity
                    )
                }
            }
        }
    }

    private var reasoningPathsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reasoning Paths", systemImage: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
                .font(.headline)

            // Show multi-hop paths first, then single-hop
            let sortedPaths = response.reasoningPaths.sorted { $0.edgeCount > $1.edgeCount }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(sortedPaths.prefix(15)) { path in
                    ReasoningPathRow(path: path)
                }
            }
        }
    }

    private var graphPathsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Supporting Relationships", systemImage: "arrow.triangle.branch")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(response.graphPaths.prefix(10)) { path in
                    GraphPathRow(path: path)
                }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sources", systemImage: "doc.text")
                .font(.headline)

            ForEach(response.sourceArticles) { article in
                SourceArticleRow(article: article)
            }
        }
    }

    // MARK: - Deep Analysis Section

    private var deepAnalysisSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Deep Analysis", systemImage: "sparkles")
                .font(.headline)

            if viewModel.isAnalyzing {
                // Loading state
                HStack(spacing: 12) {
                    ProgressView()
                        .controlSize(.small)
                    Text("Running multi-agent analysis...")
                        .foregroundStyle(.secondary)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.background.secondary)
                .clipShape(.rect(cornerRadius: 12))

            } else if !viewModel.isDeepAnalysisAvailable {
                // No LLM configured
                Text("Configure an LLM provider in Settings to enable deep analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 12))

            } else {
                // LLM is available - show results and/or button
                VStack(alignment: .leading, spacing: 16) {
                    // Show existing results if available
                    if let result = viewModel.deepAnalysisResult {
                        DeepAnalysisResultView(result: result)
                    }

                    // Always show the analyze button when LLM is configured
                    VStack(alignment: .leading, spacing: 12) {
                        if !viewModel.hasExistingAnalysis {
                            Text("Use AI agents to synthesize insights with academic citations and generate hypotheses.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        if viewModel.hasExistingAnalysis {
                            Button(viewModel.analyzeButtonLabel, systemImage: "sparkles") {
                                Task {
                                    await viewModel.performDeepAnalysis()
                                }
                            }
                            .buttonStyle(.bordered)
                        } else {
                            Button(viewModel.analyzeButtonLabel, systemImage: "sparkles") {
                                Task {
                                    await viewModel.performDeepAnalysis()
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 12))
                }
            }

            // Error display
            if let error = viewModel.analysisError {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.red.opacity(0.1))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
    }
}

// MARK: - Deep Analysis Result View

private struct DeepAnalysisResultView: View {
    let result: DeepAnalysisResult

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Synthesized Answer
            VStack(alignment: .leading, spacing: 8) {
                Label("Synthesized Analysis", systemImage: "text.quote")
                    .font(.subheadline)
                    .bold()

                renderMarkdown(result.synthesizedAnswer)
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.blue.opacity(0.05))
            .clipShape(.rect(cornerRadius: 12))

            // Hypotheses
            VStack(alignment: .leading, spacing: 8) {
                Label("Hypotheses & Experiments", systemImage: "lightbulb")
                    .font(.subheadline)
                    .bold()

                renderMarkdown(result.hypotheses)
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.purple.opacity(0.05))
            .clipShape(.rect(cornerRadius: 12))

            // Timestamp
            HStack {
                Text("Analyzed")
                Text(result.analyzedAt, style: .relative)
                Text("ago")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func renderMarkdown(_ text: String) -> some View {
        let markdown = try? AttributedString(
            markdown: text,
            options: .init(
                allowsExtendedAttributes: true,
                interpretedSyntax: .inlineOnlyPreservingWhitespace,
                failurePolicy: .returnPartiallyParsedIfPossible
            )
        )
        if let markdown {
            Text(markdown)
        } else {
            Text(text)
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

private struct ReasoningPathRow: View {
    let path: GraphRAGResponse.ReasoningPath

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Path description with hop count indicator
            HStack(alignment: .top, spacing: 8) {
                // Icon indicates path length
                Image(systemName: path.isMultiHop ? "arrow.triangle.2.circlepath" : "arrow.right")
                    .foregroundStyle(path.isMultiHop ? .purple : .secondary)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 4) {
                    // Path description
                    Text(path.description)
                        .font(.subheadline)

                    // Edge count badge
                    Text("\(path.edgeCount) hop\(path.edgeCount == 1 ? "" : "s")")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(path.isMultiHop ? Color.purple.opacity(0.15) : Color.secondary.opacity(0.15))
                        .foregroundStyle(path.isMultiHop ? .purple : .secondary)
                        .clipShape(.capsule)
                }
            }

            // Visual chip representation for multi-hop paths
            if path.isMultiHop {
                HStack(spacing: 4) {
                    conceptChip(path.sourceConcept, color: .blue)

                    ForEach(path.intermediateNodes, id: \.self) { node in
                        Image(systemName: "arrow.right")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        conceptChip(node, color: .orange)
                    }

                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    conceptChip(path.targetConcept, color: .green)
                }
                .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
    }

    private func conceptChip(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(.capsule)
    }
}

private struct GraphPathRow: View {
    let path: GraphRAGResponse.GraphPath

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Natural language sentence
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.purple)
                    .frame(width: 16)

                Text(path.naturalLanguageSentence)
                    .font(.subheadline)
            }

            // Visual chip representation
            HStack(spacing: 4) {
                ForEach(path.sourceNodes, id: \.self) { node in
                    Text(node)
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(.capsule)
                }

                if !path.targetNodes.isEmpty {
                    Image(systemName: "arrow.right")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    ForEach(path.targetNodes, id: \.self) { node in
                        Text(node)
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.green.opacity(0.15))
                            .foregroundStyle(.green)
                            .clipShape(.capsule)
                    }
                }
            }
            .padding(.leading, 24)

            // Provenance text if available
            if let provenance = path.provenanceText, !provenance.isEmpty {
                Text("Source: \"\(provenance)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .italic()
                    .lineLimit(2)
                    .padding(.leading, 24)
            }
        }
        .padding(.vertical, 4)
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

    struct LayoutResult {
        let size: CGSize
        let placements: [Placement]
    }

    struct Placement {
        let origin: CGPoint
        let size: CGSize
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = layout(proposal: proposal, subviews: subviews)
        return result.size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = layout(proposal: proposal, subviews: subviews)

        for (index, placement) in result.placements.enumerated() {
            subviews[index].place(
                at: CGPoint(x: bounds.minX + placement.origin.x, y: bounds.minY + placement.origin.y),
                proposal: ProposedViewSize(placement.size)
            )
        }
    }

    private func layout(proposal: ProposedViewSize, subviews: Subviews) -> LayoutResult {
        let maxWidth = proposal.width ?? .infinity
        var placements: [Placement] = []

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

            placements.append(Placement(origin: CGPoint(x: currentX, y: currentY), size: size))
            currentX += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            totalHeight = currentY + lineHeight
        }

        return LayoutResult(size: CGSize(width: maxWidth, height: totalHeight), placements: placements)
    }
}

#Preview {
    NavigationStack {
        AnswerDetailView(historyItem: QueryHistoryItem(
            id: 1,
            query: "What are the main topics discussed in recent articles?",
            answer: """
            Several events have happened recently. Here are a few examples:
            1. **AWS Community Day events**: Various AWS re:invent re:Caps were hosted around the globe.
            2. **Micron's acquisition**: Micron acquired a chipmaking campus from PSMC for $1.8 billion.
            3. **Palo Alto Networks' data platform transformation**: Partnered with Google Cloud.
            4. **ServiceNow and OpenAI partnership**: Multi-year agreement announced.
            """,
            reasoningPathsJson: """
            [{"sourceConcept":"Palo Alto Networks","targetConcept":"BigQuery","intermediateNodes":["Google Cloud","Dataflow"],"edgeCount":3},
             {"sourceConcept":"ServiceNow","targetConcept":"AI","intermediateNodes":["OpenAI"],"edgeCount":2}]
            """,
            graphPathsJson: """
            [{"id":1,"relation":"partnered with","sourceNodes":["Palo Alto Networks"],"targetNodes":["Google Cloud"],"provenanceText":"Partnered to modernize data processing."}]
            """
        ))
    }
}
