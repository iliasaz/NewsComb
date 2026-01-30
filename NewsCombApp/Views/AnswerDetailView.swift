import SwiftUI

/// View for displaying a question/answer, either from history or from a live progressive query.
struct AnswerDetailView: View {
    @State private var viewModel: AnswerDetailViewModel
    #if os(macOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    // MARK: - Initializers

    /// Creates the view from a persisted query history item (static display).
    init(historyItem: QueryHistoryItem) {
        _viewModel = State(initialValue: AnswerDetailViewModel(historyItem: historyItem))
    }

    /// Creates the view for a live query that will progressively populate.
    init(liveQuery: LiveQueryNavigation) {
        _viewModel = State(initialValue: AnswerDetailViewModel(liveQuery: liveQuery))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                questionSection

                if viewModel.isLiveQuery {
                    pipelineStatusSection
                }

                if !viewModel.answerText.isEmpty {
                    answerSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if let error = viewModel.pipelineError {
                    pipelineErrorSection(error)
                }

                if viewModel.isCompleted {
                    deepAnalysisSection
                        .transition(.opacity)
                }

                if !viewModel.relatedNodes.isEmpty {
                    relatedNodesSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !viewModel.reasoningPaths.isEmpty {
                    reasoningPathsSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !viewModel.graphPaths.isEmpty {
                    graphPathsSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                if !viewModel.sourceArticles.isEmpty {
                    sourcesSection
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }
            .padding()
            .animation(.easeInOut(duration: 0.3), value: viewModel.relatedNodes.count)
            .animation(.easeInOut(duration: 0.3), value: viewModel.reasoningPaths.count)
            .animation(.easeInOut(duration: 0.3), value: viewModel.sourceArticles.count)
            .animation(.easeInOut(duration: 0.3), value: viewModel.isCompleted)
        }
        .navigationTitle("Answer")
        .task {
            await viewModel.startPipeline()
        }
    }

    // MARK: - Pipeline Status

    private var pipelineStatusSection: some View {
        HStack(spacing: 12) {
            ProgressView()
                .controlSize(.small)
            Text(viewModel.pipelineStatus.isEmpty ? "Starting\u{2026}" : viewModel.pipelineStatus)
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12))
    }

    private func pipelineErrorSection(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
            Text(error)
                .foregroundStyle(.red)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.red.opacity(0.1))
        .clipShape(.rect(cornerRadius: 12))
    }

    // MARK: - Sections

    private var questionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Question", systemImage: "questionmark.circle")
                .font(.headline)

            Text(viewModel.question)
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
                markdown: viewModel.answerText,
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
                Text(viewModel.answerText)
                    .textSelection(.enabled)
            }

            if let generatedAt = viewModel.generatedAt {
                HStack {
                    Text("Generated")
                    Text(generatedAt, style: .relative)
                    Text("ago")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12))
    }

    private var relatedNodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Related Concepts", systemImage: "brain.head.profile")
                    .font(.headline)
                Spacer()
                #if os(macOS)
                Text("Click to open graph")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            FlowLayout(spacing: 8) {
                ForEach(viewModel.relatedNodes.prefix(15)) { node in
                    Button {
                        #if os(macOS)
                        openWindow(id: "focused-graph", value: node.id)
                        #endif
                    } label: {
                        NodeChip(
                            label: node.label,
                            type: node.nodeType,
                            similarity: node.similarity
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private var reasoningPathsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reasoning Paths", systemImage: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
                .font(.headline)

            // Show multi-hop paths first, then single-hop
            let sortedPaths = viewModel.reasoningPaths.sorted { $0.edgeCount > $1.edgeCount }

            VStack(alignment: .leading, spacing: 8) {
                ForEach(sortedPaths.prefix(15)) { path in
                    EnhancedReasoningPathRow(path: path)
                }
            }
        }
    }

    private var graphPathsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Supporting Relationships", systemImage: "arrow.triangle.branch")
                .font(.headline)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(viewModel.graphPaths.prefix(10)) { path in
                    GraphPathRow(path: path)
                }
            }
        }
    }

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sources", systemImage: "doc.text")
                .font(.headline)

            ForEach(viewModel.sourceArticles) { article in
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
                // Streaming analysis state
                VStack(alignment: .leading, spacing: 12) {
                    // Agent status
                    HStack(spacing: 12) {
                        ProgressView()
                            .controlSize(.small)
                        Text(viewModel.analysisStatus.isEmpty ? "Starting analysis\u{2026}" : viewModel.analysisStatus)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 12))

                    // Streaming synthesis text
                    if !viewModel.streamingSynthesis.isEmpty {
                        StreamingAnalysisSection(
                            title: "Synthesized Analysis",
                            systemImage: "text.quote",
                            text: viewModel.streamingSynthesis,
                            tint: .blue
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }

                    // Streaming hypotheses text
                    if !viewModel.streamingHypotheses.isEmpty {
                        StreamingAnalysisSection(
                            title: "Hypotheses & Experiments",
                            systemImage: "lightbulb",
                            text: viewModel.streamingHypotheses,
                            tint: .purple
                        )
                        .transition(.opacity.combined(with: .move(edge: .top)))
                    }
                }
                .animation(.easeInOut(duration: 0.3), value: viewModel.streamingSynthesis.isEmpty)
                .animation(.easeInOut(duration: 0.3), value: viewModel.streamingHypotheses.isEmpty)

            } else if !viewModel.isDeepAnalysisAvailable {
                // No LLM configured
                Text("Configure an LLM provider in Settings to enable deep analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 12))

            } else if viewModel.historyItem == nil {
                // Pipeline completed but not yet persisted — disable deep analysis
                Text("Save to history to enable deep analysis.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.background.secondary)
                    .clipShape(.rect(cornerRadius: 12))

            } else {
                // LLM is available and history item exists
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

// MARK: - Streaming Analysis Section

/// Displays a single agent's streaming output with a labeled header.
private struct StreamingAnalysisSection: View {
    let title: String
    let systemImage: String
    let text: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.subheadline)
                .bold()

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
                    .textSelection(.enabled)
            } else {
                Text(text)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint.opacity(0.05))
        .clipShape(.rect(cornerRadius: 12))
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
