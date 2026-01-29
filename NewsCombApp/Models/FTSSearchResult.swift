import Foundation

/// A node matched by FTS5 full-text search.
///
/// Nodes can be matched directly (their label contains the search terms)
/// or indirectly (article content mentioning the search terms is linked
/// to the node via provenance). When indirect, `articleTitle` is non-nil.
struct FTSNodeMatch: Identifiable, Sendable {
    /// The `hypergraph_node.id` primary key.
    let id: Int64
    let label: String
    let nodeType: String?
    /// FTS5 snippet with `<b>` markers around matched terms.
    let snippet: String
    /// BM25 rank (lower = better match).
    let rank: Double
    /// Article title when this node was found via chunk content (nil for direct label matches).
    let articleTitle: String?

    init(id: Int64, label: String, nodeType: String?, snippet: String, rank: Double, articleTitle: String? = nil) {
        self.id = id
        self.label = label
        self.nodeType = nodeType
        self.snippet = snippet
        self.rank = rank
        self.articleTitle = articleTitle
    }

    /// Whether this node was found via article content rather than its own label.
    var isContentDerived: Bool { articleTitle != nil }
}

/// Combined search results from both node-label and article-content FTS5 indexes.
struct GraphSearchResults: Sendable {
    let query: String
    /// Nodes matched directly by label.
    let nodeMatches: [FTSNodeMatch]
    /// Nodes derived from matching article chunk content.
    let contentDerivedNodes: [FTSNodeMatch]

    /// All node IDs that matched — directly via label or indirectly via chunk content.
    var allMatchedNodeIds: Set<Int64> {
        var ids = Set(nodeMatches.map(\.id))
        ids.formUnion(contentDerivedNodes.map(\.id))
        return ids
    }

    var isEmpty: Bool { nodeMatches.isEmpty && contentDerivedNodes.isEmpty }
    var totalCount: Int { nodeMatches.count + contentDerivedNodes.count }
}
