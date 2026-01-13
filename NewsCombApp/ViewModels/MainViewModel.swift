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

    private let database = Database.shared

    @ObservationIgnored
    private let rssService = RSSService()

    @ObservationIgnored
    private let extractService = ContentExtractService()

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
                status: .fetching
            )
        }

        let results = await rssService.fetchAllFeeds(sources: sources, extractService: extractService)

        for result in results {
            if let index = metrics.firstIndex(where: { $0.id == result.sourceId }) {
                if let error = result.error {
                    metrics[index].status = .error(error.localizedDescription)
                } else {
                    metrics[index].status = .done(itemCount: result.itemCount)
                    totalItemsFetched += result.itemCount
                }
            }
        }

        isRefreshing = false
    }

    /// Clear all articles for a specific feed source
    func clearFeedContent(sourceId: Int64) {
        do {
            let deletedCount = try database.write { db in
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
}
