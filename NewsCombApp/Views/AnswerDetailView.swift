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

    private var graphPathsSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reasoning Paths", systemImage: "point.topright.arrow.triangle.backward.to.point.bottomleft.scurvepath")
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
        AnswerDetailView(response: GraphRAGResponse(
            query: "What are the main topics discussed in recent articles?",
            answer: """
            Several events have happened recently. Here are a few examples:
            1. **AWS Community Day events**: Various AWS re:invent re:Caps were hosted around the globe, and the AWS Community Day Tel Aviv 2026 was hosted last week.
            2. **Micron's acquisition**: Micron acquired a chipmaking campus from Taiwanese outfit Powerchip Semiconductor Manufacturing Corporation (PSMC) for $1.8 billion.
            3. **Cyberattack on a Warwickshire school**: A cyberattack forced a prolonged closure of Higham Lane School in Nuneaton, but it has since reopened.
            4. **Palo Alto Networks' data platform transformation**: Palo Alto Networks partnered with Google Cloud to modernize their data processing landscape into a unified multi-tenant platform powered by Dataflow, Pub/Sub, and BigQuery.
            5. **ServiceNow and OpenAI partnership**: ServiceNow announced a multi-year agreement with OpenAI to expand customer access to OpenAI frontier models.

            These events were mentioned in the source articles: "AWS Weekly Roundup: Kiro CLI latest features, AWS European Sovereign Cloud, EC2 X8i instances, and more (January 19, 2026)", "Micron finds a way to make more DRAM with $1.8bn chip plant purchase", "Warwickshire school to reopen after cyberattack crippled IT", "How Palo Alto Networks built a multi tenant scalable Unified Data Platform", and "ServiceNow powers actionable enterprise AI with OpenAI".
            """,
            relatedNodes: [
                .init(id: 1, nodeId: "ai", label: "Artificial Intelligence", nodeType: "TOPIC", distance: 0.1),
                .init(id: 2, nodeId: "cloud", label: "Cloud Computing", nodeType: "TOPIC", distance: 0.2)
            ],
            graphPaths: [
                .init(id: 1, relation: "partnered_with", sourceNodes: ["Palo Alto Networks"], targetNodes: ["Google Cloud"], provenanceText: "Palo Alto Networks partnered with Google Cloud to modernize their data processing landscape."),
                .init(id: 2, relation: "acquired", sourceNodes: ["Micron"], targetNodes: ["PSMC"], provenanceText: "Micron acquired a chipmaking campus from PSMC for $1.8 billion."),
                .init(id: 3, relation: "announced_partnership", sourceNodes: ["ServiceNow"], targetNodes: ["OpenAI"])
            ],
            sourceArticles: [
                .init(id: 1, title: "AI Advances in 2026", link: "https://example.com", pubDate: Date(), relevantChunks: [
                    .init(id: 1, chunkIndex: 0, content: "Recent advances in AI have transformed...", distance: 0.1)
                ])
            ]
        ))
    }
}
