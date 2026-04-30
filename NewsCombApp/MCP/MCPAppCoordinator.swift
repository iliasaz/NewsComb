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

    // MARK: - Article ingestion (manual feeds)

    /// Creates a manual feed (synthetic-URL `rss_source`) so MCP-supplied
    /// articles have a parent container.
    func createManualFeed(title: String) -> String {
        logger.info("MCP triggered createManualFeed title=\(title, privacy: .public)")
        let service = ArticleIngestionService()
        do {
            let source = try service.createManualFeed(title: title)
            mainViewModel.loadSources()
            let id = source.id ?? -1
            return "Created manual feed #\(id): '\(source.title ?? "")'. Use ingest_article with source_id=\(id) to add articles."
        } catch let error as ArticleIngestionService.IngestionError {
            return "Create manual feed failed: \(error.localizedDescription)"
        } catch {
            return "Create manual feed failed: \(error.localizedDescription)"
        }
    }

    /// Inserts an MCP-supplied article into an existing manual feed.
    func ingestArticle(
        sourceId: Int64,
        title: String,
        body: String,
        link: String?,
        author: String?,
        pubDate: Date?,
        guid: String?
    ) -> String {
        logger.info("MCP triggered ingestArticle sourceId=\(sourceId, privacy: .public) title=\(title, privacy: .public)")
        let service = ArticleIngestionService()
        do {
            let item = try service.ingestArticle(
                sourceId: sourceId,
                title: title,
                body: body,
                link: link,
                author: author,
                pubDate: pubDate,
                guid: guid
            )
            mainViewModel.loadSources()
            let id = item.id ?? -1
            return "Ingested article #\(id) into feed #\(sourceId): '\(item.title)' (\(item.fullContent?.count ?? 0) chars)."
        } catch let error as ArticleIngestionService.IngestionError {
            return "Ingest article failed: \(error.localizedDescription)"
        } catch {
            return "Ingest article failed: \(error.localizedDescription)"
        }
    }

    /// Surgically drops one article's downstream graph state and re-runs
    /// per-article extraction. Equivalent in effect to a "delete-and-reprocess
    /// just this row" path that the batch upserts can't provide cleanly.
    func reprocessArticle(feedItemId: Int64) async -> String {
        logger.info("MCP triggered reprocessArticle feedItemId=\(feedItemId, privacy: .public)")
        let service = HypergraphService()
        do {
            let outcome = try await service.reprocessArticle(feedItemId: feedItemId)
            mainViewModel.loadHypergraphStats()
            let stats = outcome.deletionStats
            return """
            Reprocessed article #\(outcome.feedItemId) in \(outcome.processingTimeMs)ms. \
            Dropped \(stats.chunksDeleted) chunks, \(stats.edgesDeleted) edges, \
            \(stats.provenanceDeleted) provenance rows, and swept \(stats.orphanNodesDeleted) orphan node(s). \
            Re-extracted: \(outcome.chunksAdded) chunks, \(outcome.edgesAdded) edges, \
            \(outcome.nodesAdded) participating node(s).
            """
        } catch let error as HypergraphServiceError {
            return "Reprocess article failed: \(error.localizedDescription)"
        } catch {
            return "Reprocess article failed: \(error.localizedDescription)"
        }
    }

    /// Re-fetches `full_content` for a single article via the Postlight pipeline.
    func refreshArticle(feedItemId: Int64) async -> String {
        logger.info("MCP triggered refreshArticle feedItemId=\(feedItemId, privacy: .public)")
        let service = ArticleIngestionService()
        do {
            let outcome = try await service.refreshArticle(feedItemId: feedItemId)
            mainViewModel.loadSources()
            let delta = outcome.contentLengthDelta
            let sign = delta >= 0 ? "+" : ""
            var msg = "Refreshed article #\(outcome.feedItemId): \(outcome.previousContentLength) → \(outcome.newContentLength) chars (\(sign)\(delta))."
            if outcome.linkChanged {
                msg += " Link redirected to \(outcome.newLink)."
            }
            return msg
        } catch let error as ArticleIngestionService.IngestionError {
            return "Refresh article failed: \(error.localizedDescription)"
        } catch {
            return "Refresh article failed: \(error.localizedDescription)"
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

    /// Re-clusters a single existing cluster — equivalent to the "Split" menu in ThemeDetailView.
    func splitCluster(
        clusterId: Int64,
        minClusterSize: Int?,
        minSamples: Int?,
        relabel: Bool,
        dryRun: Bool,
        wait: Bool
    ) async -> String {
        if themesViewModel.isRebuilding {
            return "Theme operation already running: \(themesViewModel.rebuildStatus). Use get_app_status to monitor."
        }
        logger.info("MCP triggered splitCluster id=\(clusterId, privacy: .public) dryRun=\(dryRun, privacy: .public) wait=\(wait, privacy: .public)")

        guard let cluster = themesViewModel.clusters.first(where: { $0.clusterId == clusterId }) else {
            return "Cluster #\(clusterId) not found. Use get_themes to list available cluster IDs."
        }

        if wait {
            let outcome = await themesViewModel.splitCluster(
                cluster,
                minClusterSize: minClusterSize,
                minSamples: minSamples,
                relabel: relabel,
                dryRun: dryRun
            )
            return Self.describe(outcome: outcome, originalClusterId: clusterId)
        } else {
            Task {
                await themesViewModel.splitCluster(
                    cluster,
                    minClusterSize: minClusterSize,
                    minSamples: minSamples,
                    relabel: relabel,
                    dryRun: dryRun
                )
            }
            return "Started \(dryRun ? "split preview" : "cluster split") for #\(clusterId) in background. Poll get_app_status to monitor progress."
        }
    }

    /// Formats a `ThemeSplitOutcome` for an MCP response.
    private static func describe(outcome: ThemeClusterViewModel.ThemeSplitOutcome, originalClusterId: Int64) -> String {
        switch outcome {
        case .unchanged(let suggestion):
            return "Cluster #\(originalClusterId) split produced no meaningful subdivision. \(suggestion)"
        case .dryRun(let sizes, let unfitted):
            let sizesStr = sizes.map { "\($0)" }.joined(separator: ", ")
            return "DRY RUN — splitting cluster #\(originalClusterId) would produce \(sizes.count) sub-cluster(s) of sizes [\(sizesStr)] and leave \(unfitted) event(s) unfitted (they would stay attached to the parent). Re-invoke without dry_run to create tentative children."
        case .split(let newIds, let unfitted):
            let idsStr = newIds.map { "#\($0)" }.joined(separator: ", ")
            return "Cluster #\(originalClusterId) split into \(newIds.count) tentative sub-theme(s): \(idsStr). \(unfitted) event(s) didn't fit any sub-theme and remain in the parent. Use get_theme_details on each new ID to inspect, then call save_split or discard_split."
        case .failed(let error):
            return "Split failed: \(error)"
        }
    }

    // MARK: - Noise Pools

    /// Returns the current noise-pool cluster IDs (read-only snapshot).
    func identifyNoisePools() -> String {
        let ids = themesViewModel.noisePoolClusterIds.sorted()
        guard !ids.isEmpty else {
            return "No noise-pool clusters detected. The size distribution doesn't have outliers above the current IQR multiplier."
        }
        let lookup = Dictionary(uniqueKeysWithValues: themesViewModel.clusters.map { ($0.clusterId, $0) })
        let lines = ids.map { id -> String in
            guard let c = lookup[id] else { return "#\(id) (unknown)" }
            return "#\(id) — \(c.size) events — \(c.label ?? "Untitled")"
        }
        return "Noise-pool clusters (likely absorption pools, not real themes):\n" + lines.joined(separator: "\n")
    }

    /// Drops the named noise-pool clusters (or all currently-flagged when ids is nil).
    func dropNoisePools(ids: [Int64]?, wait: Bool) async -> String {
        if themesViewModel.isRebuilding {
            return "Theme operation already running: \(themesViewModel.rebuildStatus). Use get_app_status to monitor."
        }
        let resolved = ids ?? Array(themesViewModel.noisePoolClusterIds)
        guard !resolved.isEmpty else {
            return "No noise-pool clusters to drop."
        }
        logger.info("MCP triggered dropNoisePools count=\(resolved.count, privacy: .public) wait=\(wait, privacy: .public)")

        if wait {
            switch await themesViewModel.dropNoisePools(ids: resolved) {
            case .success(let count):
                return "Dropped \(count) of \(resolved.count) noise-pool cluster(s). Saved sub-themes were unlinked. Underlying graph data preserved."
            case .failure(let error):
                return "Drop noise pools failed: \(error.message)"
            }
        } else {
            Task { _ = await themesViewModel.dropNoisePools(ids: resolved) }
            return "Started drop of \(resolved.count) noise-pool cluster(s) in background."
        }
    }

    // MARK: - Focused Theme Extraction

    func extractTheme(
        parentClusterId: Int64,
        queryText: String,
        topK: Int,
        similarityThreshold: Float,
        relabel: Bool,
        dryRun: Bool,
        wait: Bool
    ) async -> String {
        if themesViewModel.isRebuilding {
            return "Theme operation already running: \(themesViewModel.rebuildStatus). Use get_app_status to monitor."
        }
        guard let parent = themesViewModel.clusters.first(where: { $0.clusterId == parentClusterId }) else {
            return "Cluster #\(parentClusterId) not found."
        }
        logger.info("MCP triggered extractTheme parent=\(parentClusterId, privacy: .public) wait=\(wait, privacy: .public)")

        if wait {
            let outcome = await themesViewModel.extractTheme(
                parent: parent,
                queryText: queryText,
                topK: topK,
                similarityThreshold: similarityThreshold,
                relabel: relabel,
                dryRun: dryRun
            )
            switch outcome {
            case .extracted(let newId, let count, let topScore):
                let scoreStr = String(format: "%.3f", topScore)
                if dryRun {
                    return "DRY RUN — extracting '\(queryText)' from #\(parentClusterId) would match \(count) event(s) (top similarity \(scoreStr))."
                }
                return "Extracted '\(queryText)' from #\(parentClusterId) into tentative sub-theme #\(newId): \(count) event(s) (top similarity \(scoreStr)). Use save_split or discard_split to commit/undo."
            case .noMatches(let topScore):
                let scoreStr = String(format: "%.3f", topScore)
                return "No events in #\(parentClusterId) matched '\(queryText)' above the threshold. Best score was \(scoreStr) — try a lower threshold or rephrase."
            case .failed(let error):
                return "Extract failed: \(error)"
            }
        } else {
            Task {
                _ = await themesViewModel.extractTheme(
                    parent: parent,
                    queryText: queryText,
                    topK: topK,
                    similarityThreshold: similarityThreshold,
                    relabel: relabel,
                    dryRun: dryRun
                )
            }
            return "Started extract of '\(queryText)' from #\(parentClusterId) in background."
        }
    }

    // MARK: - Save / Discard / Delete

    /// Promotes tentative children of a parent to permanent sub-themes.
    func saveSplit(parentClusterId: Int64, wait: Bool) async -> String {
        if themesViewModel.isRebuilding {
            return "Theme operation already running: \(themesViewModel.rebuildStatus). Use get_app_status to monitor."
        }
        guard let parent = themesViewModel.clusters.first(where: { $0.clusterId == parentClusterId }) else {
            return "Cluster #\(parentClusterId) not found."
        }
        logger.info("MCP triggered saveSplit parent=\(parentClusterId, privacy: .public) wait=\(wait, privacy: .public)")

        if wait {
            switch await themesViewModel.saveSplit(parent: parent) {
            case .success(let count):
                return "Saved split of #\(parentClusterId): \(count) tentative sub-theme(s) promoted to permanent."
            case .failure(let error):
                return "Save split failed: \(error.message)"
            }
        } else {
            Task { _ = await themesViewModel.saveSplit(parent: parent) }
            return "Started save split for #\(parentClusterId) in background."
        }
    }

    /// Removes tentative children of a parent.
    func discardSplit(parentClusterId: Int64, wait: Bool) async -> String {
        if themesViewModel.isRebuilding {
            return "Theme operation already running: \(themesViewModel.rebuildStatus). Use get_app_status to monitor."
        }
        guard let parent = themesViewModel.clusters.first(where: { $0.clusterId == parentClusterId }) else {
            return "Cluster #\(parentClusterId) not found."
        }
        logger.info("MCP triggered discardSplit parent=\(parentClusterId, privacy: .public) wait=\(wait, privacy: .public)")

        if wait {
            switch await themesViewModel.discardSplit(parent: parent) {
            case .success(let count):
                return "Discarded split of #\(parentClusterId): \(count) tentative sub-theme(s) removed."
            case .failure(let error):
                return "Discard split failed: \(error.message)"
            }
        } else {
            Task { _ = await themesViewModel.discardSplit(parent: parent) }
            return "Started discard split for #\(parentClusterId) in background."
        }
    }

    /// Deletes a cluster row. Underlying graph data is preserved. Saved children of a
    /// parent get unlinked (become top-level themes); tentative children are deleted.
    func deleteCluster(clusterId: Int64, wait: Bool) async -> String {
        if themesViewModel.isRebuilding {
            return "Theme operation already running: \(themesViewModel.rebuildStatus). Use get_app_status to monitor."
        }
        guard let cluster = themesViewModel.clusters.first(where: { $0.clusterId == clusterId }) else {
            return "Cluster #\(clusterId) not found."
        }
        logger.info("MCP triggered deleteCluster id=\(clusterId, privacy: .public) wait=\(wait, privacy: .public)")

        if wait {
            switch await themesViewModel.deleteCluster(cluster) {
            case .success(let res):
                var parts: [String] = ["Cluster #\(clusterId) deleted (underlying graph data preserved)."]
                if res.unlinkedChildCount > 0 {
                    parts.append("\(res.unlinkedChildCount) sub-theme(s) unlinked and promoted to top-level.")
                }
                if res.promotedTentativeChildCount > 0 {
                    parts.append("(\(res.promotedTentativeChildCount) of the unlinked children were tentative — they are now regular standalone themes.)")
                }
                return parts.joined(separator: " ")
            case .failure(let error):
                return "Delete cluster failed: \(error.message)"
            }
        } else {
            Task { _ = await themesViewModel.deleteCluster(cluster) }
            return "Started delete cluster for #\(clusterId) in background."
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

    // MARK: - Settings updates

    /// Side-effect hook invoked by `update_settings` after a successful write.
    ///
    /// `update_settings` is purely a write to the per-workspace `app_settings`
    /// table. Most categories are read fresh by their downstream consumers on
    /// the next pipeline run, so no eager invalidation is needed. The one
    /// exception is `.llm`: if `embedding_provider` or `embedding_dimension`
    /// changed, the `vec0` virtual tables must be dropped and recreated at
    /// the new dimension before any further embedding work can happen.
    /// `Database.rebuildVec0TablesIfNeeded()` is a no-op if the dimension
    /// already matches, so calling it unconditionally is safe and cheap.
    func didUpdateSettings(category: SettingsCategory) async {
        switch category {
        case .llm:
            do {
                try await Database.current.rebuildVec0TablesIfNeeded()
            } catch {
                logger.error(
                    "Failed to rebuild vec0 tables after LLM settings change: \(error.localizedDescription, privacy: .public)"
                )
            }
        case .extraction, .clustering, .rag, .analysis, .feeds, .simulation:
            // No immediate side effect: the next pipeline run reads the new
            // values directly from `app_settings`.
            break
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
