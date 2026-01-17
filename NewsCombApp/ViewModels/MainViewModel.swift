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

    // Hypergraph processing state
    var isProcessingHypergraph = false
    var hypergraphProgress: (processed: Int, total: Int) = (0, 0)
    var hypergraphProcessingStatus: String = ""
    var hypergraphStats: HypergraphStatistics?

    private let database = Database.shared

    @ObservationIgnored
    private let rssService = RSSService()

    @ObservationIgnored
    private let extractService = ContentExtractService()

    @ObservationIgnored
    private let hypergraphService = HypergraphService()

    func loadSources() {
        do {
            let sources = try database.read { db in
                try RSSSource.fetchAll(db)
            }

            metrics = sources.compactMap { source in
                guard let id = source.id else { return nil }
                return SourceMetric(
                    id: id,
                    sourceName: source.title ?? source.url,
                    sourceURL: source.url,
                    status: .pending
                )
            }
        } catch {
            errorMessage = "Failed to load sources: \(error.localizedDescription)"
        }
    }

    func refreshFeeds() async {
        guard !isRefreshing else { return }

        isRefreshing = true
        defer { isRefreshing = false }
        totalItemsFetched = 0

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
        // isRefreshing is reset by defer
    }

    /// Clear all articles from all feed sources
    func clearAllArticles() {
        do {
            _ = try database.write { db in
                try FeedItem.deleteAll(db)
            }

            // Reset all metrics to pending
            for index in metrics.indices {
                metrics[index].status = .pending
            }

            totalItemsFetched = 0
            errorMessage = nil
        } catch {
            errorMessage = "Failed to clear all articles: \(error.localizedDescription)"
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

        do {
            let processedCount = try await hypergraphService.processUnprocessedArticles { [weak self] processed, total, title in
                self?.hypergraphProgress = (processed, total)
                self?.hypergraphProcessingStatus = "Processing: \(title)"
            }

            hypergraphProcessingStatus = "Completed: \(processedCount) articles processed"

            // Update stats
            loadHypergraphStats()
        } catch {
            errorMessage = "Hypergraph processing failed: \(error.localizedDescription)"
            hypergraphProcessingStatus = "Failed"
        }

        isProcessingHypergraph = false
    }

    /// Loads hypergraph statistics.
    func loadHypergraphStats() {
        do {
            hypergraphStats = try hypergraphService.getStatistics()
        } catch {
            // Silently fail - stats are not critical
        }
    }
}
