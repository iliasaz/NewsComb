import Foundation
import OSLog

/// Bridges MCP tool calls to the app's `@MainActor` view models so that tool-driven
/// actions (refresh feeds, process knowledge graph, rebuild themes) update exactly the
/// same observable state the UI is bound to.
///
/// MCP tools call into this coordinator from a non-MainActor context. The coordinator
/// hops to the main actor, invokes the same view-model method the toolbar button would
/// have invoked, and either awaits completion or fires-and-forgets while returning a
/// "started" message so the model can poll progress with `get_app_status`.
@MainActor
final class MCPAppCoordinator {

    static let shared = MCPAppCoordinator()

    let mainViewModel = MainViewModel.shared
    let themesViewModel = ThemeClusterViewModel.shared

    private let logger = Logger(subsystem: "com.newscomb.app", category: "MCPCoordinator")

    private init() {}

    // MARK: - Feed refresh

    /// Triggers the same action as the "Refresh" toolbar button.
    func refreshFeeds(wait: Bool) async -> String {
        if mainViewModel.isRefreshing {
            return "Feed refresh is already in progress (fetched \(mainViewModel.totalItemsFetched) items so far). Use get_app_status to monitor."
        }
        logger.info("MCP triggered refreshFeeds (wait=\(wait, privacy: .public))")

        if wait {
            await mainViewModel.refreshFeeds()
            let new = mainViewModel.newArticlesFromLastRefresh
            return "Feed refresh complete. Fetched \(mainViewModel.totalItemsFetched) items across \(mainViewModel.metrics.count) sources; \(new) new article\(new == 1 ? "" : "s") added."
        } else {
            Task { await mainViewModel.refreshFeeds() }
            return "Started feed refresh in background. Poll get_app_status to monitor progress."
        }
    }

    // MARK: - Knowledge graph processing

    /// Triggers the same action as the "Process Knowledge Graph" toolbar button.
    func processKnowledgeGraph(wait: Bool) async -> String {
        if mainViewModel.isProcessingHypergraph {
            let p = mainViewModel.hypergraphProgress
            return "Knowledge graph processing is already running (\(p.processed)/\(p.total) articles). Use get_app_status to monitor."
        }
        if mainViewModel.embeddingDimensionMismatch {
            return "Cannot process: embedding model dimension changed. Reset the knowledge graph first."
        }
        logger.info("MCP triggered processKnowledgeGraph (wait=\(wait, privacy: .public))")

        if wait {
            await mainViewModel.processUnprocessedArticles()
            let p = mainViewModel.hypergraphProgress
            let stats = mainViewModel.hypergraphStats
            var summary = "Knowledge graph processing complete. Processed \(p.processed) of \(p.total) article(s)."
            if let stats {
                summary += " Graph now has \(stats.nodeCount) concepts and \(stats.edgeCount) relationships."
            }
            return summary
        } else {
            Task { await mainViewModel.processUnprocessedArticles() }
            return "Started knowledge graph processing in background. Poll get_app_status to monitor progress."
        }
    }

    /// Triggers the same action as the "Stop" button shown while processing.
    func cancelKnowledgeGraphProcessing() -> String {
        guard mainViewModel.isProcessingHypergraph else {
            return "No knowledge graph processing is currently running."
        }
        logger.info("MCP triggered cancelKnowledgeGraphProcessing")
        mainViewModel.cancelHypergraphProcessing()
        return "Cancellation requested. The current article will finish, then processing will stop."
    }

    // MARK: - Theme clustering

    /// Triggers the same action as the "Recompute All" themes menu item.
    func rebuildThemes(wait: Bool) async -> String {
        if themesViewModel.isRebuilding {
            let pct = (themesViewModel.rebuildProgress * 100).formatted(.number.precision(.fractionLength(0)))
            return "Theme clustering is already running (\(pct)% — \(themesViewModel.rebuildStatus)). Use get_app_status to monitor."
        }
        logger.info("MCP triggered rebuildThemes (wait=\(wait, privacy: .public))")

        if wait {
            await themesViewModel.rebuildClusters()
            if let err = themesViewModel.rebuildError {
                return "Theme clustering failed: \(err)"
            }
            let count = themesViewModel.clusters.count
            let total = themesViewModel.totalEvents
            let noise = themesViewModel.noiseCount
            return "Theme clustering complete. Built \(count) theme\(count == 1 ? "" : "s") from \(total - noise) clustered event\(total - noise == 1 ? "" : "s") (\(noise) noise)."
        } else {
            Task { await themesViewModel.rebuildClusters() }
            return "Started theme clustering in background. Poll get_app_status to monitor progress."
        }
    }

    /// Triggers the same action as the "Regenerate Summaries" themes menu item.
    func regenerateThemeSummaries(wait: Bool) async -> String {
        if themesViewModel.isRebuilding {
            return "Theme operation already running: \(themesViewModel.rebuildStatus). Use get_app_status to monitor."
        }
        guard !themesViewModel.clusters.isEmpty else {
            return "No themes to regenerate. Run rebuild_themes first."
        }
        logger.info("MCP triggered regenerateThemeSummaries (wait=\(wait, privacy: .public))")

        if wait {
            await themesViewModel.regenerateSummaries()
            if let err = themesViewModel.rebuildError {
                return "Summary regeneration failed: \(err)"
            }
            return "Theme summaries regenerated for \(themesViewModel.clusters.count) theme(s)."
        } else {
            Task { await themesViewModel.regenerateSummaries() }
            return "Started summary regeneration in background. Poll get_app_status to monitor progress."
        }
    }

    // MARK: - Status snapshots

    /// Snapshot of all in-flight UI operations for `get_app_status`.
    func snapshotStatus() -> AppStatusSnapshot {
        AppStatusSnapshot(
            isRefreshingFeeds: mainViewModel.isRefreshing,
            feedsTotalItemsFetched: mainViewModel.totalItemsFetched,
            feedsNewArticles: mainViewModel.newArticlesFromLastRefresh,
            feedsLastRefresh: mainViewModel.lastRefreshTime,
            isProcessingHypergraph: mainViewModel.isProcessingHypergraph,
            hypergraphProgressProcessed: mainViewModel.hypergraphProgress.processed,
            hypergraphProgressTotal: mainViewModel.hypergraphProgress.total,
            hypergraphStatus: mainViewModel.hypergraphProcessingStatus,
            currentProcessingArticle: mainViewModel.currentProcessingArticle,
            recentlyExtractedEntities: mainViewModel.recentlyExtractedEntities,
            isSimplifyingGraph: mainViewModel.isSimplifyingGraph,
            isResettingGraph: mainViewModel.isResettingGraph,
            embeddingDimensionMismatch: mainViewModel.embeddingDimensionMismatch,
            isRebuildingThemes: themesViewModel.isRebuilding,
            themeRebuildProgress: themesViewModel.rebuildProgress,
            themeRebuildStatus: themesViewModel.rebuildStatus,
            themeCount: themesViewModel.clusters.count,
            themeTotalEvents: themesViewModel.totalEvents,
            themeNoiseCount: themesViewModel.noiseCount,
            lastError: mainViewModel.errorMessage ?? themesViewModel.rebuildError
        )
    }
}

/// Plain-data snapshot returned to MCP clients.
struct AppStatusSnapshot: Sendable {
    let isRefreshingFeeds: Bool
    let feedsTotalItemsFetched: Int
    let feedsNewArticles: Int
    let feedsLastRefresh: Date?

    let isProcessingHypergraph: Bool
    let hypergraphProgressProcessed: Int
    let hypergraphProgressTotal: Int
    let hypergraphStatus: String
    let currentProcessingArticle: String
    let recentlyExtractedEntities: [String]
    let isSimplifyingGraph: Bool
    let isResettingGraph: Bool
    let embeddingDimensionMismatch: Bool

    let isRebuildingThemes: Bool
    let themeRebuildProgress: Double
    let themeRebuildStatus: String
    let themeCount: Int
    let themeTotalEvents: Int
    let themeNoiseCount: Int

    let lastError: String?
}
