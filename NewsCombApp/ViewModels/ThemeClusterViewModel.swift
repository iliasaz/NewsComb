import Foundation
import GRDB
import Observation
import OSLog

/// View model for the story themes list, supporting cluster display and rebuild.
@MainActor
@Observable
final class ThemeClusterViewModel {

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

    /// Clears the last rebuild error.
    func clearError() {
        rebuildError = nil
    }
}
