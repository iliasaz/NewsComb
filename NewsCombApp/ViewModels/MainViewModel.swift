import Foundation
import Observation
import GRDB

enum FetchStatus: Equatable, Hashable {
    case pending
    case fetching
    case done(itemCount: Int)
    case error(String)
}

struct SourceMetric: Identifiable, Equatable, Hashable {
    let id: Int64
    let sourceName: String
    let sourceURL: String
    var status: FetchStatus

    var itemCount: Int {
        if case .done(let count) = status {
            return count
        }
        return 0
    }
}

@MainActor
@Observable
class MainViewModel {
    var metrics: [SourceMetric] = []
    var isRefreshing = false
    var totalItemsFetched = 0
    var errorMessage: String?

    // RSS source management
    var newSourceURL: String = ""

    // Feed statistics
    var newArticlesFromLastRefresh: Int = 0
    var lastRefreshTime: Date?

    // Hypergraph processing state
    var isProcessingHypergraph = false
    var hypergraphProgress: (processed: Int, total: Int) = (0, 0)
    var hypergraphProcessingStatus: String = ""
    var hypergraphStats: HypergraphStatistics?
    var currentProcessingArticle: String = ""
    var recentlyExtractedEntities: [String] = []

    // Graph reset state
    var isResettingGraph = false

    // Graph simplification state (set during auto-simplify at end of processing)
    var isSimplifyingGraph = false

    private let database = Database.shared

    @ObservationIgnored
    private let rssService = RSSService()

    @ObservationIgnored
    private let extractService = ContentExtractService()

    @ObservationIgnored
    private let hypergraphService = HypergraphService()

    @ObservationIgnored
    private let nodeMergingService = NodeMergingService()

    // MARK: - Computed Statistics

    /// Number of feeds that have at least one article
    var nonEmptyFeedsCount: Int {
        metrics.filter { $0.itemCount > 0 }.count
    }

    /// Total number of articles across all feeds
    var totalArticlesCount: Int {
        metrics.reduce(0) { $0 + $1.itemCount }
    }

    func loadSources() {
        do {
            let sources = try database.read { db in
                try RSSSource.fetchAll(db)
            }

            metrics = try sources.compactMap { source -> SourceMetric? in
                guard let id = source.id else { return nil }

                // Load actual item count for this source
                let itemCount = try database.read { db in
                    try FeedItem.filter(FeedItem.Columns.sourceId == id).fetchCount(db)
                }

                return SourceMetric(
                    id: id,
                    sourceName: source.title ?? source.url,
                    sourceURL: source.url,
                    status: itemCount > 0 ? .done(itemCount: itemCount) : .pending
                )
            }
        } catch {
            errorMessage = "Failed to load sources: \(error.localizedDescription)"
        }
    }

    // MARK: - RSS Source Management

    /// Add a new RSS source from the URL field.
    func addSource() {
        let trimmed = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        addSourceURL(trimmed)
        newSourceURL = ""
    }

    /// Paste multiple RSS sources from text (newline or comma separated).
    func pasteMultipleSources(_ text: String) {
        let urls = text.components(separatedBy: CharacterSet.newlines)
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("http") }

        for url in urls {
            addSourceURL(url)
        }
    }

    private func addSourceURL(_ url: String) {
        let normalizedURL = normalizeURL(url)

        // Check if URL already exists (normalized comparison)
        let existingURLs = metrics.map { normalizeURL($0.sourceURL) }
        if existingURLs.contains(normalizedURL) {
            errorMessage = "This feed URL already exists in your sources."
            return
        }

        do {
            _ = try database.write { db in
                try RSSSource(url: normalizedURL).insert(db, onConflict: .ignore)
            }
            loadSources()
        } catch {
            errorMessage = "Failed to add source: \(error.localizedDescription)"
        }
    }

    /// Normalize URL for consistent comparison.
    private func normalizeURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Lowercase scheme and host
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // Remove default ports
        if let port = components.port {
            if (components.scheme == "http" && port == 80) ||
               (components.scheme == "https" && port == 443) {
                components.port = nil
            }
        }

        // Remove trailing slash from path
        if components.path.hasSuffix("/") && components.path.count > 1 {
            components.path = String(components.path.dropLast())
        }

        return components.string ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Delete an RSS source by its ID.
    func deleteSource(sourceId: Int64) {
        do {
            _ = try database.write { db in
                try RSSSource.filter(RSSSource.Columns.id == sourceId).deleteAll(db)
            }
            loadSources()
        } catch {
            errorMessage = "Failed to delete source: \(error.localizedDescription)"
        }
    }

    func refreshFeeds() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        totalItemsFetched = 0
        newArticlesFromLastRefresh = 0

        // Count existing articles before refresh
        let articlesBeforeRefresh = getTotalArticleCountFromDatabase()

        var sources: [RSSSource] = []
        do {
            sources = try database.read { db in
                try RSSSource.fetchAll(db)
            }
        } catch {
            errorMessage = "Failed to load sources: \(error.localizedDescription)"
            isRefreshing = false
            return
        }

        metrics = sources.compactMap { source in
            guard let id = source.id else { return nil }
            return SourceMetric(
                id: id,
                sourceName: source.title ?? source.url,
                sourceURL: source.url,
                status: .fetching
            )
        }

        // Use streaming updates - update UI as each feed completes
        await rssService.fetchAllFeedsStreaming(sources: sources, extractService: extractService) { result in
            if let index = self.metrics.firstIndex(where: { $0.id == result.sourceId }) {
                if let error = result.error {
                    self.metrics[index].status = .error(error.localizedDescription)
                } else {
                    self.metrics[index].status = .done(itemCount: result.itemCount)
                    self.totalItemsFetched += result.itemCount
                }
            }
        }

        // Calculate new articles downloaded
        let articlesAfterRefresh = getTotalArticleCountFromDatabase()
        newArticlesFromLastRefresh = max(0, articlesAfterRefresh - articlesBeforeRefresh)
        lastRefreshTime = Date()
        // isRefreshing is reset by defer
    }

    /// Gets the total article count from the database
    private func getTotalArticleCountFromDatabase() -> Int {
        do {
            return try database.read { db in
                try FeedItem.fetchCount(db)
            }
        } catch {
            return 0
        }
    }

    /// Clear all articles and hypergraph data from all feed sources.
    /// Preserves only the RSS source URLs.
    func clearAllArticles() {
        do {
            try database.write { db in
                // Clear all dependent tables first (respect foreign key constraints)
                // Order matters: delete from dependent tables first

                // 1. Clustering / themes (reference edges as event IDs)
                try db.execute(sql: "DELETE FROM cluster_exemplars")
                try db.execute(sql: "DELETE FROM cluster_members")
                try db.execute(sql: "DELETE FROM event_cluster")
                try db.execute(sql: "DELETE FROM clusters")

                // 2. Event vectors (reference edges as event IDs)
                try db.execute(sql: "DELETE FROM event_vectors")

                // 3. Clear provenance (references edges and feed items)
                try db.execute(sql: "DELETE FROM article_edge_provenance")

                // 4. Clear article processing status (references feed items)
                try db.execute(sql: "DELETE FROM article_hypergraph")

                // 5. Clear merge history (references nodes)
                try db.execute(sql: "DELETE FROM node_merge_history")

                // 6. Clear embedding metadata (references nodes and chunks)
                try db.execute(sql: "DELETE FROM chunk_embedding_metadata")
                try db.execute(sql: "DELETE FROM node_embedding_metadata")

                // 7. Clear embeddings (virtual tables)
                try db.execute(sql: "DELETE FROM chunk_embedding")
                try db.execute(sql: "DELETE FROM node_embedding")

                // 8. Clear incidences (references edges and nodes)
                try db.execute(sql: "DELETE FROM hypergraph_incidence")

                // 9. Clear edges
                try db.execute(sql: "DELETE FROM hypergraph_edge")

                // 10. Clear nodes
                try db.execute(sql: "DELETE FROM hypergraph_node")

                // 11. Clear article chunks
                try db.execute(sql: "DELETE FROM article_chunk")

                // 12. Finally, clear feed items
                try FeedItem.deleteAll(db)
            }

            // Reset all metrics to pending
            for index in metrics.indices {
                metrics[index].status = .pending
            }

            totalItemsFetched = 0
            hypergraphStats = nil
            errorMessage = nil
        } catch {
            errorMessage = "Failed to clear all data: \(error.localizedDescription)"
        }
    }

    /// Reset the knowledge graph, removing all extracted data while preserving articles and feeds.
    func resetKnowledgeGraph() {
        guard !isResettingGraph else { return }
        isResettingGraph = true

        Task.detached { [database] in
            do {
                try database.write { db in
                    // Drop FTS triggers first — they fire on DELETE from content
                    // tables and corrupt the index if it has already been cleared.
                    try db.execute(sql: "DROP TRIGGER IF EXISTS fts_node_ai")
                    try db.execute(sql: "DROP TRIGGER IF EXISTS fts_node_ad")
                    try db.execute(sql: "DROP TRIGGER IF EXISTS fts_node_au")
                    try db.execute(sql: "DROP TRIGGER IF EXISTS fts_chunk_ai")
                    try db.execute(sql: "DROP TRIGGER IF EXISTS fts_chunk_ad")
                    try db.execute(sql: "DROP TRIGGER IF EXISTS fts_chunk_au")

                    // Clustering / themes
                    try db.execute(sql: "DELETE FROM cluster_exemplars")
                    try db.execute(sql: "DELETE FROM cluster_members")
                    try db.execute(sql: "DELETE FROM event_cluster")
                    try db.execute(sql: "DELETE FROM clusters")

                    // Provenance
                    try db.execute(sql: "DELETE FROM article_edge_provenance")

                    // Merge history
                    try db.execute(sql: "DELETE FROM node_merge_history")

                    // Embedding metadata
                    try db.execute(sql: "DELETE FROM chunk_embedding_metadata")
                    try db.execute(sql: "DELETE FROM node_embedding_metadata")

                    // Drop and recreate vec0 tables with current dimension (clamped to max)
                    let rawDim: Int
                    if let setting = try AppSettings
                        .filter(AppSettings.Columns.key == AppSettings.embeddingDimension)
                        .fetchOne(db),
                       let value = Int(setting.value) {
                        rawDim = value
                    } else {
                        rawDim = AppSettings.defaultEmbeddingDimension
                    }
                    let embDim = min(rawDim, AppSettings.maxEmbeddingDimension)
                    let eventVecDim = 3 * embDim + 12  // 12 = RelationFamily.count

                    try db.execute(sql: "DROP TABLE IF EXISTS event_vectors")
                    try db.execute(sql: "DROP TABLE IF EXISTS chunk_embedding")
                    try db.execute(sql: "DROP TABLE IF EXISTS node_embedding")

                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE node_embedding USING vec0(
                            node_id INTEGER PRIMARY KEY,
                            embedding float[\(embDim)]
                        )
                    """)
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE chunk_embedding USING vec0(
                            chunk_id INTEGER PRIMARY KEY,
                            embedding float[\(embDim)]
                        )
                    """)
                    try db.execute(sql: """
                        CREATE VIRTUAL TABLE event_vectors USING vec0(
                            event_id INTEGER PRIMARY KEY,
                            vec float[\(eventVecDim)]
                        )
                    """)

                    // Update active dimension to match
                    try db.execute(
                        sql: """
                            INSERT INTO app_settings (key, value) VALUES (?, ?)
                            ON CONFLICT(key) DO UPDATE SET value = excluded.value
                        """,
                        arguments: [AppSettings.activeEmbeddingDimension, String(embDim)]
                    )

                    // Hypergraph structure
                    try db.execute(sql: "DELETE FROM hypergraph_incidence")
                    try db.execute(sql: "DELETE FROM hypergraph_edge")
                    try db.execute(sql: "DELETE FROM hypergraph_node")

                    // Article chunks (intermediate processing artifacts)
                    try db.execute(sql: "DELETE FROM article_chunk")

                    // Reset processing status so articles can be re-processed
                    try db.execute(sql: "DELETE FROM article_hypergraph")

                    // Query history (answers reference graph data)
                    try db.execute(sql: "DELETE FROM query_history")

                    // Rebuild FTS indexes (now empty) and recreate sync triggers
                    try db.execute(sql: "INSERT INTO fts_node(fts_node) VALUES('rebuild')")
                    try db.execute(sql: "INSERT INTO fts_chunk(fts_chunk) VALUES('rebuild')")

                    try db.execute(sql: """
                        CREATE TRIGGER fts_node_ai AFTER INSERT ON hypergraph_node BEGIN
                            INSERT INTO fts_node(rowid, label) VALUES (new.id, new.label);
                        END;
                        CREATE TRIGGER fts_node_ad AFTER DELETE ON hypergraph_node BEGIN
                            INSERT INTO fts_node(fts_node, rowid, label) VALUES('delete', old.id, old.label);
                        END;
                        CREATE TRIGGER fts_node_au AFTER UPDATE ON hypergraph_node BEGIN
                            INSERT INTO fts_node(fts_node, rowid, label) VALUES('delete', old.id, old.label);
                            INSERT INTO fts_node(rowid, label) VALUES (new.id, new.label);
                        END;
                        CREATE TRIGGER fts_chunk_ai AFTER INSERT ON article_chunk BEGIN
                            INSERT INTO fts_chunk(rowid, content) VALUES (new.id, new.content);
                        END;
                        CREATE TRIGGER fts_chunk_ad AFTER DELETE ON article_chunk BEGIN
                            INSERT INTO fts_chunk(fts_chunk, rowid, content) VALUES('delete', old.id, old.content);
                        END;
                        CREATE TRIGGER fts_chunk_au AFTER UPDATE ON article_chunk BEGIN
                            INSERT INTO fts_chunk(fts_chunk, rowid, content) VALUES('delete', old.id, old.content);
                            INSERT INTO fts_chunk(rowid, content) VALUES (new.id, new.content);
                        END;
                    """)
                }

                await MainActor.run { [weak self] in
                    self?.hypergraphStats = nil
                    self?.isResettingGraph = false
                }
            } catch {
                await MainActor.run { [weak self] in
                    self?.errorMessage = "Failed to reset knowledge graph: \(error.localizedDescription)"
                    self?.isResettingGraph = false
                }
            }
        }
    }

    /// Clear all articles for a specific feed source
    func clearFeedContent(sourceId: Int64) {
        do {
            _ = try database.write { db in
                try FeedItem.filter(FeedItem.Columns.sourceId == sourceId).deleteAll(db)
            }

            // Update the metric to show cleared status
            if let index = metrics.firstIndex(where: { $0.id == sourceId }) {
                metrics[index].status = .pending
            }

            errorMessage = nil
        } catch {
            errorMessage = "Failed to clear feed content: \(error.localizedDescription)"
        }
    }

    /// Refresh a single feed source
    func refreshSingleFeed(sourceId: Int64) async {
        guard let source = try? database.read({ db in
            try RSSSource.filter(RSSSource.Columns.id == sourceId).fetchOne(db)
        }) else {
            errorMessage = "Source not found"
            return
        }

        // Update status to fetching
        if let index = metrics.firstIndex(where: { $0.id == sourceId }) {
            metrics[index].status = .fetching
        }

        let results = await rssService.fetchAllFeeds(sources: [source], extractService: extractService)

        if let result = results.first {
            if let index = metrics.firstIndex(where: { $0.id == result.sourceId }) {
                if let error = result.error {
                    metrics[index].status = .error(error.localizedDescription)
                } else {
                    metrics[index].status = .done(itemCount: result.itemCount)
                }
            }
        }
    }

    /// Get all articles grouped by source for export
    func getAllArticlesGroupedBySource() -> [(sourceName: String, articles: [FeedItem])] {
        do {
            let sources = try database.read { db in
                try RSSSource.fetchAll(db)
            }

            var result: [(sourceName: String, articles: [FeedItem])] = []

            for source in sources {
                guard let sourceId = source.id else { continue }

                let articles = try database.read { db in
                    try FeedItem.filter(FeedItem.Columns.sourceId == sourceId)
                        .order(FeedItem.Columns.pubDate.desc)
                        .fetchAll(db)
                }

                if !articles.isEmpty {
                    let sourceName = source.title ?? source.url
                    result.append((sourceName: sourceName, articles: articles))
                }
            }

            return result
        } catch {
            errorMessage = "Failed to load articles: \(error.localizedDescription)"
            return []
        }
    }

    // MARK: - Hypergraph Processing

    /// Checks if hypergraph processing is available (LLM provider configured).
    func isHypergraphProcessingAvailable() -> Bool {
        hypergraphService.isConfigured()
    }

    /// Gets the count of unprocessed articles with content.
    func getUnprocessedArticleCount() -> Int {
        do {
            return try hypergraphService.getUnprocessedArticles().count
        } catch {
            return 0
        }
    }

    /// Processes all unprocessed articles to extract knowledge graphs.
    func processUnprocessedArticles() async {
        guard !isProcessingHypergraph else { return }

        // Check if service is configured
        guard hypergraphService.isConfigured() else {
            errorMessage = "No LLM provider configured. Configure Ollama or OpenRouter in Settings."
            return
        }

        isProcessingHypergraph = true
        hypergraphProgress = (0, 0)
        hypergraphProcessingStatus = "Starting..."
        currentProcessingArticle = ""
        recentlyExtractedEntities = []

        do {
            let processedCount = try await hypergraphService.processUnprocessedArticles(
                progressCallback: { [weak self] processed, total, title in
                    self?.hypergraphProgress = (processed, total)
                    self?.hypergraphProcessingStatus = "Processing: \(title)"
                },
                detailCallback: { [weak self] detail in
                    switch detail.kind {
                    case .articleStarted(let title):
                        self?.currentProcessingArticle = title
                    case .entitiesExtracted(_, let entities):
                        self?.recentlyExtractedEntities = entities
                    }
                }
            )

            // Update stats before simplification
            loadHypergraphStats()

            // Auto-simplify: merge similar nodes after extraction
            currentProcessingArticle = ""
            recentlyExtractedEntities = []
            var simplifyMessage = ""
            if canSimplifyGraph() {
                hypergraphProcessingStatus = "Simplifying graph…"
                isSimplifyingGraph = true
                do {
                    let result = try await nodeMergingService.simplifyHypergraph()
                    if result.mergedPairs > 0 {
                        simplifyMessage = ", merged \(result.mergedPairs) similar node\(result.mergedPairs == 1 ? "" : "s")"
                    }
                    loadHypergraphStats()
                } catch {
                    // Simplification failure is non-fatal — log but don't block
                    simplifyMessage = " (simplification failed)"
                }
                isSimplifyingGraph = false
            }

            hypergraphProcessingStatus = "Completed: \(processedCount) articles processed\(simplifyMessage)"
        } catch HypergraphServiceError.cancelled {
            hypergraphProcessingStatus = "Cancelled at \(hypergraphProgress.processed)/\(hypergraphProgress.total)"
            // Update stats even on cancel - some articles may have been processed
            loadHypergraphStats()
        } catch {
            errorMessage = "Hypergraph processing failed: \(error.localizedDescription)"
            hypergraphProcessingStatus = "Failed"
        }

        currentProcessingArticle = ""
        recentlyExtractedEntities = []
        isProcessingHypergraph = false
    }

    /// Cancels the current hypergraph processing operation.
    func cancelHypergraphProcessing() {
        hypergraphService.cancelProcessing()
        hypergraphProcessingStatus = "Cancelling..."
    }

    /// Loads hypergraph statistics.
    func loadHypergraphStats() {
        do {
            hypergraphStats = try hypergraphService.getStatistics()
        } catch {
            // Silently fail - stats are not critical
        }
    }

    // MARK: - Graph Simplification

    /// Checks if the hypergraph has enough data for simplification.
    private func canSimplifyGraph() -> Bool {
        guard let stats = hypergraphStats else { return false }
        return stats.nodeCount > 1
    }
}
