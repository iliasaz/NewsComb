import Foundation
import GRDB
import Observation
import OSLog

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
