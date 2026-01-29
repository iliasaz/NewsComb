import Foundation

/// Represents a source chunk that provides provenance for a graph node or edge.
/// Used to show users where knowledge graph data originated from.
struct ProvenanceSource: Identifiable, Sendable {
    /// Unique identifier combining article and chunk for deduplication.
    var id: String { "\(feedItemId)-\(chunkIndex)" }

    /// The feed item (article) ID this provenance comes from.
    let feedItemId: Int64

    /// The article title.
    let title: String

    /// The article URL link, if available.
    let link: String?

    /// The publication date of the article.
    let pubDate: Date?

    /// The text content of the source chunk.
    let chunkText: String

    /// The chunk index within the article.
    let chunkIndex: Int

    init(
        feedItemId: Int64,
        title: String,
        link: String?,
        pubDate: Date?,
        chunkText: String,
        chunkIndex: Int
    ) {
        self.feedItemId = feedItemId
        self.title = title
        self.link = link
        self.pubDate = pubDate
        self.chunkText = chunkText
        self.chunkIndex = chunkIndex
    }
}
