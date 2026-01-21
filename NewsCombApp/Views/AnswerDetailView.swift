import SwiftUI

/// View for displaying a saved question/answer from history.
struct AnswerDetailView: View {
    let response: GraphRAGResponse

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                questionSection
                answerSection

                if !response.relatedNodes.isEmpty {
                    relatedNodesSection
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

    private var sourcesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Sources", systemImage: "doc.text")
                .font(.headline)

            ForEach(response.sourceArticles) { article in
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
        AnswerDetailView(response: GraphRAGResponse(
            query: "What are the main topics discussed in recent articles?",
            answer: "Based on the knowledge graph, the main topics include AI developments, cloud computing, cybersecurity, and technology industry trends.",
            relatedNodes: [
                .init(id: 1, nodeId: "ai", label: "Artificial Intelligence", nodeType: "TOPIC", distance: 0.1),
                .init(id: 2, nodeId: "cloud", label: "Cloud Computing", nodeType: "TOPIC", distance: 0.2)
            ],
            sourceArticles: [
                .init(id: 1, title: "AI Advances in 2026", link: "https://example.com", pubDate: Date(), relevantChunks: [
                    .init(id: 1, chunkIndex: 0, content: "Recent advances in AI have transformed...", distance: 0.1)
                ])
            ]
        ))
    }
}
