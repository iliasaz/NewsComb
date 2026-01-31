import Foundation
import GRDB
import Observation
import OSLog

/// View model for a single story theme's detail view.
@MainActor
@Observable
final class ThemeDetailViewModel {

    /// An event (hyperedge) with its participants and provenance for display.
    struct EventDisplay: Identifiable {
        let id: Int64
        let verb: String
        let sources: [String]
        let targets: [String]
        let articleTitle: String?
        let articleLink: String?

        /// Formatted subject-verb-object sentence.
        var sentence: String {
            let s = sources.joined(separator: ", ")
            let t = targets.joined(separator: ", ")
            if !s.isEmpty && !t.isEmpty {
                return "\(s) \(verb) \(t)"
            } else if !s.isEmpty {
                return "\(s) \(verb)"
            } else {
                return verb
            }
        }
    }

    // MARK: - Display State

    /// The cluster being displayed.
    let cluster: StoryCluster

    /// Exemplar events with full context.
    private(set) var exemplarEvents: [EventDisplay] = []

    /// All member events (loaded on demand).
    private(set) var memberEvents: [EventDisplay] = []

    /// Whether all members have been loaded.
    private(set) var allMembersLoaded = false

    // MARK: - Internal

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "ThemeDetailViewModel")

    init(cluster: StoryCluster) {
        self.cluster = cluster
    }

    // MARK: - Loading

    /// Loads exemplar events for this cluster.
    func loadExemplars() {
        do {
            let exemplarIds = try database.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT event_id FROM cluster_exemplars
                    WHERE cluster_id = ?
                    ORDER BY rank
                """, arguments: [cluster.clusterId])
                .map { row -> Int64 in row["event_id"] }
            }

            exemplarEvents = try loadEventDisplays(eventIds: exemplarIds)
            logger.info("Loaded \(self.exemplarEvents.count) exemplar events for cluster \(self.cluster.clusterId)")
        } catch {
            logger.error("Failed to load exemplars: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Loads all member events for this cluster.
    func loadAllMembers() {
        guard !allMembersLoaded else { return }

        do {
            let memberIds = try database.read { db in
                try Row.fetchAll(db, sql: """
                    SELECT event_id FROM cluster_members
                    WHERE cluster_id = ?
                    ORDER BY membership DESC
                """, arguments: [cluster.clusterId])
                .map { row -> Int64 in row["event_id"] }
            }

            memberEvents = try loadEventDisplays(eventIds: memberIds)
            allMembersLoaded = true
            logger.info("Loaded \(self.memberEvents.count) member events for cluster \(self.cluster.clusterId)")
        } catch {
            logger.error("Failed to load members: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Private

    /// Loads event display data for a set of event IDs.
    private func loadEventDisplays(eventIds: [Int64]) throws -> [EventDisplay] {
        guard !eventIds.isEmpty else { return [] }

        return try database.read { db in
            var events: [EventDisplay] = []

            for eventId in eventIds {
                // Load edge
                guard let edge = try Row.fetchOne(db, sql: """
                    SELECT id, label FROM hypergraph_edge WHERE id = ?
                """, arguments: [eventId]) else { continue }

                let verb: String = edge["label"]

                // Load participants
                let incidences = try Row.fetchAll(db, sql: """
                    SELECT hn.label, hi.role
                    FROM hypergraph_incidence hi
                    JOIN hypergraph_node hn ON hn.id = hi.node_id
                    WHERE hi.edge_id = ?
                    ORDER BY hi.role, hi.position
                """, arguments: [eventId])

                var sources: [String] = []
                var targets: [String] = []
                for inc in incidences {
                    let label: String = inc["label"]
                    let role: String = inc["role"]
                    if role == "source" {
                        sources.append(label)
                    } else {
                        targets.append(label)
                    }
                }

                // Load provenance (first matching article)
                let provenance = try Row.fetchOne(db, sql: """
                    SELECT fi.title, fi.link
                    FROM article_edge_provenance aep
                    JOIN feed_item fi ON fi.id = aep.feed_item_id
                    WHERE aep.edge_id = ?
                    LIMIT 1
                """, arguments: [eventId])

                let articleTitle: String? = provenance?["title"]
                let articleLink: String? = provenance?["link"]

                events.append(EventDisplay(
                    id: eventId,
                    verb: verb,
                    sources: sources,
                    targets: targets,
                    articleTitle: articleTitle,
                    articleLink: articleLink
                ))
            }

            return events
        }
    }
}
