import SwiftUI

/// Sheet view displaying provenance sources for a graph node or edge.
/// Shows the article chunks that generated the knowledge graph entity.
struct ProvenanceSheetView: View {
    let label: String
    let sources: [ProvenanceSource]
    let isNode: Bool
    /// Optional search query whose terms will be highlighted in chunk text.
    var highlightQuery: String? = nil

    @Environment(\.dismiss) private var dismiss

    /// Group sources by article for cleaner display.
    private var groupedSources: [(feedItemId: Int64, title: String, link: String?, pubDate: Date?, chunks: [ProvenanceSource])] {
        var groups: [Int64: (title: String, link: String?, pubDate: Date?, chunks: [ProvenanceSource])] = [:]

        for source in sources {
            if var existing = groups[source.feedItemId] {
                existing.chunks.append(source)
                groups[source.feedItemId] = existing
            } else {
                groups[source.feedItemId] = (source.title, source.link, source.pubDate, [source])
            }
        }

        return groups.map { (feedItemId: $0.key, title: $0.value.title, link: $0.value.link, pubDate: $0.value.pubDate, chunks: $0.value.chunks) }
            .sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if sources.isEmpty {
                    emptyState
                } else {
                    sourcesList
                }
            }
            .navigationTitle("Sources for \"\(label)\"")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", systemImage: "xmark.circle.fill") {
                        dismiss()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "No Sources Found",
            systemImage: "doc.questionmark",
            description: Text("No provenance information is available for this \(isNode ? "concept" : "relationship").")
        )
    }

    private var sourcesList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("From \(groupedSources.count) article\(groupedSources.count == 1 ? "" : "s"):")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal)

                ForEach(groupedSources, id: \.feedItemId) { group in
                    ArticleProvenanceCard(
                        title: group.title,
                        link: group.link,
                        pubDate: group.pubDate,
                        chunks: group.chunks,
                        highlightQuery: highlightQuery
                    )
                }
            }
            .padding()
        }
    }
}

/// Card displaying provenance from a single article.
private struct ArticleProvenanceCard: View {
    let title: String
    let link: String?
    let pubDate: Date?
    let chunks: [ProvenanceSource]
    var highlightQuery: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Article header
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.headline)
                    .lineLimit(2)

                if let pubDate {
                    Text(pubDate, style: .date)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Chunk excerpts
            ForEach(chunks) { chunk in
                ChunkExcerptView(
                    chunkText: chunk.chunkText,
                    chunkIndex: chunk.chunkIndex,
                    highlightQuery: highlightQuery
                )
            }

            // Open article link
            if let link, let url = URL(string: link) {
                Link(destination: url) {
                    HStack {
                        Spacer()
                        Label("Open Article", systemImage: "arrow.up.right.square")
                            .font(.subheadline)
                    }
                }
                .padding(.top, 4)
            }
        }
        .padding()
        .background(.background.secondary)
        .clipShape(.rect(cornerRadius: 12))
    }
}

/// View displaying a single chunk excerpt with quote styling.
/// When `highlightQuery` is set, matching terms are highlighted with a yellow background.
private struct ChunkExcerptView: View {
    let chunkText: String
    let chunkIndex: Int
    var highlightQuery: String? = nil

    /// Truncate chunk text for display, stripping HTML and keeping it readable.
    private var displayText: String {
        let cleaned = chunkText.strippingHTMLTags()
        let maxLength = 300
        if cleaned.count <= maxLength {
            return cleaned
        }
        let endIndex = cleaned.index(cleaned.startIndex, offsetBy: maxLength)
        return String(cleaned[..<endIndex]) + "..."
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Quote bar
            Rectangle()
                .fill(.blue.opacity(0.5))
                .frame(width: 3)

            VStack(alignment: .leading, spacing: 4) {
                if let query = highlightQuery, !query.isEmpty {
                    HighlightedText(text: displayText, query: query)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                } else {
                    Text(displayText)
                        .font(.callout)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

#Preview {
    ProvenanceSheetView(
        label: "Apple Inc",
        sources: [
            ProvenanceSource(
                feedItemId: 1,
                title: "Tech Giants Report Record Earnings",
                link: "https://example.com/article1",
                pubDate: Date(),
                chunkText: "Apple Inc reported record revenue of $120 billion for the quarter, driven by strong iPhone sales and growing services revenue. The company's market capitalization reached new highs.",
                chunkIndex: 0
            ),
            ProvenanceSource(
                feedItemId: 1,
                title: "Tech Giants Report Record Earnings",
                link: "https://example.com/article1",
                pubDate: Date(),
                chunkText: "CEO Tim Cook highlighted the company's commitment to innovation and sustainability initiatives.",
                chunkIndex: 1
            ),
            ProvenanceSource(
                feedItemId: 2,
                title: "Apple Announces New Product Line",
                link: "https://example.com/article2",
                pubDate: Date().addingTimeInterval(-86400),
                chunkText: "Apple unveiled its latest lineup of products at the annual event, showcasing significant improvements in performance and battery life.",
                chunkIndex: 0
            )
        ],
        isNode: true,
        highlightQuery: "Apple revenue"
    )
}
