import Foundation
import GRDB
import Observation
import OSLog

/// Lightweight error wrapper so ViewModel methods can return `Result<T, ThemeOperationError>`
/// (Swift requires the failure type to conform to `Error`; a bare `String` does not).
struct ThemeOperationError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// View model for the story themes list, supporting cluster display and rebuild.
@MainActor
@Observable
final class ThemeClusterViewModel {

    /// Shared singleton so the ThemesView and the MCP server operate on the same state.
    static let shared = ThemeClusterViewModel()

    // MARK: - Search State

    /// Current search query text bound to the search bar.
    var searchText: String = "" {
        didSet { performSearch() }
    }

    /// Whether a search is active (non-empty query).
    var isSearching: Bool { !searchText.isEmpty }

    /// Filtered clusters matching the search, with FTS snippets.
    private(set) var searchResults: [ClusterSearchResult] = []

    /// A cluster search hit with highlighted snippet.
    struct ClusterSearchResult: Identifiable {
        let cluster: StoryCluster
        let snippet: String
        var id: Int64 { cluster.clusterId }
    }

    // MARK: - Display State

    /// All clusters from the latest build, sorted by size descending.
    private(set) var clusters: [StoryCluster] = []

    /// Total number of events that were clustered.
    private(set) var totalEvents: Int = 0

    /// Number of events classified as noise (not in any cluster).
    private(set) var noiseCount: Int = 0

    // MARK: - Pipeline State

    /// Whether a clustering rebuild is in progress.
    private(set) var isRebuilding = false

    /// Human-readable status of the current pipeline phase.
    private(set) var rebuildStatus: String = ""

    /// Fractional progress of the rebuild (0..1).
    private(set) var rebuildProgress: Double = 0

    /// Error message from the last rebuild attempt.
    private(set) var rebuildError: String?

    // MARK: - Internal

    private let clusteringService = ClusteringService()
    private let clusterLabelingService = ClusterLabelingService()
    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "ThemeClusterViewModel")

    // MARK: - Loading

    /// Loads clusters from the database.
    func loadClusters() {
        do {
            clusters = try database.read { db in
                try StoryCluster
                    .order(StoryCluster.Columns.size.desc)
                    .fetchAll(db)
            }

            (totalEvents, noiseCount) = try database.read { db in
                let total = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_cluster") ?? 0
                let noise = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_cluster WHERE cluster_id = -1") ?? 0
                return (total, noise)
            }

            recomputeNoisePools()

            logger.info("Loaded \(self.clusters.count) clusters")
        } catch {
            logger.error("Failed to load clusters: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Whether clusters have been computed at least once.
    var hasClusters: Bool {
        !clusters.isEmpty
    }

    // MARK: - Rebuild

    /// Triggers a full clustering rebuild.
    func rebuildClusters() async {
        guard !isRebuilding else { return }

        isRebuilding = true
        rebuildError = nil
        rebuildProgress = 0
        rebuildStatus = "Starting\u{2026}"

        do {
            try await clusteringService.runFullPipeline(
                statusCallback: { [weak self] status in
                    self?.rebuildStatus = status
                },
                progressCallback: { [weak self] progress in
                    self?.rebuildProgress = progress
                }
            )

            loadClusters()
            rebuildStatus = ""
            logger.info("Cluster rebuild completed successfully")

        } catch is CancellationError {
            rebuildStatus = ""
            logger.info("Cluster rebuild cancelled")
        } catch {
            logger.error("Cluster rebuild failed: \(error.localizedDescription, privacy: .public)")
            rebuildError = error.localizedDescription
        }

        isRebuilding = false
    }

    // MARK: - Tree views

    /// Top-level clusters (no parent), sorted by size descending. Used as the
    /// root of the directory-style tree in `ThemesView`.
    var topLevelClusters: [StoryCluster] {
        clusters
            .filter { $0.parentClusterId == nil }
            .sorted { $0.size > $1.size }
    }

    /// Children of a parent cluster, sorted by size descending.
    func subClusters(of parentId: Int64) -> [StoryCluster] {
        clusters
            .filter { $0.parentClusterId == parentId }
            .sorted { $0.size > $1.size }
    }

    /// Whether this cluster has any tentative children awaiting Save / Discard.
    func hasTentativeChildren(_ clusterId: Int64) -> Bool {
        clusters.contains { $0.parentClusterId == clusterId && $0.isTentative }
    }

    // MARK: - Noise Pools

    /// Cluster IDs that the IQR-on-log(size) outlier rule flagged as noise pools.
    /// Recomputed inside `loadClusters()`.
    private(set) var noisePoolClusterIds: Set<Int64> = []

    /// Re-runs the noise-pool detector against the current top-level clusters and
    /// the user's IQR multiplier setting.
    private func recomputeNoisePools() {
        let multiplier: Float = {
            do {
                return try database.read { db -> Float in
                    if let setting = try AppSettings
                        .filter(AppSettings.Columns.key == AppSettings.noisePoolIQRMultiplier)
                        .fetchOne(db),
                       let value = Float(setting.value) {
                        return value
                    }
                    return AppSettings.defaultNoisePoolIQRMultiplier
                }
            } catch {
                return AppSettings.defaultNoisePoolIQRMultiplier
            }
        }()
        let sizes = clusters
            .filter { $0.parentClusterId == nil && $0.size > 1 }
            .map { (clusterId: $0.clusterId, size: $0.size) }
        let result = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: multiplier)
        noisePoolClusterIds = Set(result.noisePoolClusterIds)
    }

    /// Drops the named noise-pool clusters by reusing the existing delete-cluster
    /// path (so saved children get unlinked and tentative children are removed).
    /// Returns the number of clusters successfully dropped.
    @discardableResult
    func dropNoisePools(ids: [Int64]) async -> Result<Int, ThemeOperationError> {
        guard !isRebuilding else { return .failure(ThemeOperationError(message: "Another theme operation is already running.")) }
        isRebuilding = true
        rebuildStatus = "Dropping \(ids.count) noise-pool cluster(s)\u{2026}"
        defer { isRebuilding = false }

        var dropped = 0
        for id in ids {
            do {
                _ = try await clusteringService.deleteCluster(id)
                dropped += 1
            } catch {
                logger.warning("Failed to drop noise-pool #\(id): \(error.localizedDescription, privacy: .public)")
            }
        }
        loadClusters()
        rebuildStatus = ""
        logger.info("Dropped \(dropped) of \(ids.count) noise-pool cluster(s)")
        return .success(dropped)
    }

    // MARK: - Split

    /// Cluster IDs whose split is currently running. Drives the in-progress
    /// row highlight in `ThemesView`.
    private(set) var splittingClusterIds: Set<Int64> = []

    /// Outcome of a `splitCluster` invocation, surfaced for the view to react.
    enum ThemeSplitOutcome: Sendable {
        case unchanged(suggestion: String)
        case split(newClusterIds: [Int64], unfitted: Int)
        case dryRun(predictedSizes: [Int], unfitted: Int)
        case failed(String)
    }

    /// Re-clusters a single existing cluster's members and inserts the discovered
    /// sub-clusters as **tentative children** under the parent. The parent is left
    /// intact. Use `saveSplit` / `discardSplit` to commit or undo.
    @discardableResult
    func splitCluster(
        _ cluster: StoryCluster,
        minClusterSize: Int? = nil,
        minSamples: Int? = nil,
        relabel: Bool = true,
        dryRun: Bool = false
    ) async -> ThemeSplitOutcome {
        guard !splittingClusterIds.contains(cluster.clusterId) else {
            return .failed("Cluster #\(cluster.clusterId) is already being split.")
        }
        guard !isRebuilding else {
            return .failed("Another theme operation is already running.")
        }

        splittingClusterIds.insert(cluster.clusterId)
        isRebuilding = true
        rebuildError = nil
        rebuildProgress = 0
        rebuildStatus = dryRun
            ? "Previewing split of #\(cluster.clusterId)\u{2026}"
            : "Splitting #\(cluster.clusterId)\u{2026}"
        defer {
            splittingClusterIds.remove(cluster.clusterId)
            isRebuilding = false
        }

        do {
            let result = try await clusteringService.splitCluster(
                clusterId: cluster.clusterId,
                minClusterSizeOverride: minClusterSize,
                minSamplesOverride: minSamples,
                relabel: relabel,
                dryRun: dryRun,
                statusCallback: { [weak self] status in
                    self?.rebuildStatus = status
                },
                progressCallback: { [weak self] progress in
                    self?.rebuildProgress = progress
                }
            )

            if !dryRun {
                loadClusters()
            }
            rebuildStatus = ""

            if result.unchanged {
                return .unchanged(
                    suggestion: "Try a smaller Min Cluster Size — the current value found \(result.newClusterSizes.count) sub-cluster(s)."
                )
            }
            if result.dryRun {
                return .dryRun(
                    predictedSizes: result.newClusterSizes.map(\.size),
                    unfitted: result.unfittedCount
                )
            }
            return .split(
                newClusterIds: result.newClusterSizes.compactMap(\.id),
                unfitted: result.unfittedCount
            )
        } catch {
            logger.error("Split cluster failed: \(error.localizedDescription, privacy: .public)")
            rebuildError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Focused Theme Extraction

    enum ThemeExtractOutcome: Sendable {
        case extracted(newClusterId: Int64, matchedCount: Int, topScore: Float)
        case noMatches(topScore: Float)
        case failed(String)
    }

    /// Extracts events from a parent cluster matching a free-text phrase, persisting
    /// them as a tentative sub-theme under the parent. Drives the in-progress highlight
    /// just like `splitCluster` so the user can navigate away while it runs.
    @discardableResult
    func extractTheme(
        parent: StoryCluster,
        queryText: String,
        topK: Int = 200,
        similarityThreshold: Float = 0.45,
        relabel: Bool = true,
        dryRun: Bool = false
    ) async -> ThemeExtractOutcome {
        guard !splittingClusterIds.contains(parent.clusterId) else {
            return .failed("Cluster #\(parent.clusterId) is already being split or extracted.")
        }
        guard !isRebuilding else {
            return .failed("Another theme operation is already running.")
        }

        splittingClusterIds.insert(parent.clusterId)
        isRebuilding = true
        rebuildError = nil
        rebuildProgress = 0
        rebuildStatus = dryRun
            ? "Previewing extract from #\(parent.clusterId)\u{2026}"
            : "Extracting from #\(parent.clusterId)\u{2026}"
        defer {
            splittingClusterIds.remove(parent.clusterId)
            isRebuilding = false
        }

        do {
            let result = try await clusteringService.extractTheme(
                parentClusterId: parent.clusterId,
                queryText: queryText,
                topK: topK,
                similarityThreshold: similarityThreshold,
                relabel: relabel,
                dryRun: dryRun,
                statusCallback: { [weak self] status in
                    self?.rebuildStatus = status
                },
                progressCallback: { [weak self] progress in
                    self?.rebuildProgress = progress
                }
            )

            if !dryRun {
                loadClusters()
            }
            rebuildStatus = ""

            if let newId = result.newClusterId {
                return .extracted(newClusterId: newId, matchedCount: result.matchedCount, topScore: result.topSimilarityScore)
            }
            return .noMatches(topScore: result.topSimilarityScore)
        } catch {
            logger.error("Extract theme failed: \(error.localizedDescription, privacy: .public)")
            rebuildError = error.localizedDescription
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Save / Discard / Delete

    /// Promotes tentative children of `parent` to permanent sub-themes.
    @discardableResult
    func saveSplit(parent: StoryCluster) async -> Result<Int, ThemeOperationError> {
        guard !isRebuilding else { return .failure(ThemeOperationError(message: "Another theme operation is already running.")) }
        isRebuilding = true
        rebuildStatus = "Saving split of #\(parent.clusterId)\u{2026}"
        defer { isRebuilding = false }

        do {
            let count = try await clusteringService.saveSplit(parentClusterId: parent.clusterId)
            loadClusters()
            rebuildStatus = ""
            logger.info("Saved split of #\(parent.clusterId): \(count) child(ren) promoted")
            return .success(count)
        } catch {
            rebuildError = error.localizedDescription
            return .failure(ThemeOperationError(message: error.localizedDescription))
        }
    }

    /// Removes all tentative children of `parent`.
    @discardableResult
    func discardSplit(parent: StoryCluster) async -> Result<Int, ThemeOperationError> {
        guard !isRebuilding else { return .failure(ThemeOperationError(message: "Another theme operation is already running.")) }
        isRebuilding = true
        rebuildStatus = "Discarding split of #\(parent.clusterId)\u{2026}"
        defer { isRebuilding = false }

        do {
            let count = try await clusteringService.discardSplit(parentClusterId: parent.clusterId)
            loadClusters()
            rebuildStatus = ""
            logger.info("Discarded split of #\(parent.clusterId): \(count) tentative child(ren) removed")
            return .success(count)
        } catch {
            rebuildError = error.localizedDescription
            return .failure(ThemeOperationError(message: error.localizedDescription))
        }
    }

    /// Deletes a cluster row and its dependents. Underlying graph data is preserved.
    @discardableResult
    func deleteCluster(_ cluster: StoryCluster) async -> Result<ClusteringService.DeleteResult, ThemeOperationError> {
        guard !isRebuilding else { return .failure(ThemeOperationError(message: "Another theme operation is already running.")) }
        isRebuilding = true
        rebuildStatus = "Deleting #\(cluster.clusterId)\u{2026}"
        defer { isRebuilding = false }

        do {
            let result = try await clusteringService.deleteCluster(cluster.clusterId)
            loadClusters()
            rebuildStatus = ""
            logger.info("Deleted #\(cluster.clusterId): \(result.unlinkedChildCount) child(ren) unlinked (\(result.promotedTentativeChildCount) of which were tentative, now promoted)")
            return .success(result)
        } catch {
            rebuildError = error.localizedDescription
            return .failure(ThemeOperationError(message: error.localizedDescription))
        }
    }

    /// Re-runs only the LLM labeling step for existing clusters.
    func regenerateSummaries() async {
        guard !isRebuilding else { return }
        guard let buildId = clusters.first?.buildId else {
            rebuildError = "No clusters to regenerate summaries for."
            return
        }

        isRebuilding = true
        rebuildError = nil
        rebuildProgress = 0
        rebuildStatus = "Regenerating summaries\u{2026}"

        await clusterLabelingService.labelClusters(
            buildId: buildId,
            statusCallback: { [weak self] status in
                self?.rebuildStatus = status
            },
            progressCallback: { [weak self] progress in
                self?.rebuildProgress = progress
            }
        )

        loadClusters()
        rebuildStatus = ""
        logger.info("Summary regeneration completed")

        isRebuilding = false
    }

    /// Clears the last rebuild error.
    func clearError() {
        rebuildError = nil
    }

    // MARK: - Search

    /// The clusters to display — filtered results when searching, all clusters otherwise.
    var displayedClusters: [StoryCluster] {
        isSearching ? searchResults.map(\.cluster) : clusters
    }

    /// Returns the search snippet for a cluster, if it was found via search.
    func snippet(for clusterId: Int64) -> String? {
        searchResults.first { $0.cluster.clusterId == clusterId }?.snippet
    }

    private var searchTask: Task<Void, Never>?

    /// Runs a debounced FTS5 search on cluster labels and summaries.
    private func performSearch() {
        searchTask?.cancel()

        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            searchResults = []
            return
        }

        searchTask = Task {
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            executeSearch(query: query)
        }
    }

    private func executeSearch(query: String) {
        let sanitized = Self.sanitizeFTSQuery(query)
        guard !sanitized.isEmpty else {
            searchResults = []
            return
        }

        do {
            searchResults = try database.read { db in
                let rows = try Row.fetchAll(db, sql: """
                    SELECT
                        c.*,
                        snippet(fts_cluster, 0, '<b>', '</b>', '\u{2026}', 32) AS title_snippet,
                        snippet(fts_cluster, 1, '<b>', '</b>', '\u{2026}', 48) AS summary_snippet,
                        bm25(fts_cluster) AS rank
                    FROM fts_cluster
                    JOIN clusters c ON c.cluster_id = fts_cluster.rowid
                    WHERE fts_cluster MATCH ?
                    ORDER BY rank
                    LIMIT 50
                """, arguments: [sanitized])

                return rows.compactMap { row -> ClusterSearchResult? in
                    guard let cluster = try? StoryCluster(row: row) else { return nil }
                    // Prefer summary snippet since it's more informative;
                    // fall back to title snippet
                    let titleSnippet: String? = row["title_snippet"]
                    let summarySnippet: String? = row["summary_snippet"]
                    let snippet = summarySnippet ?? titleSnippet ?? cluster.label ?? ""
                    return ClusterSearchResult(cluster: cluster, snippet: snippet)
                }
            }
        } catch {
            logger.error("Theme search failed: \(error.localizedDescription, privacy: .public)")
            searchResults = []
        }
    }

    /// Sanitizes user input for FTS5 MATCH queries.
    static func sanitizeFTSQuery(_ input: String) -> String {
        let words = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }

        guard !words.isEmpty else { return "" }

        var quoted = words.map { word in
            let escaped = word.replacing("\"", with: "\"\"")
            return "\"\(escaped)\""
        }

        // Append prefix wildcard to last token for type-ahead matching
        if var last = quoted.last {
            last = String(last.dropLast()) + "*\""
            quoted[quoted.count - 1] = last
        }

        return quoted.joined(separator: " ")
    }
}
