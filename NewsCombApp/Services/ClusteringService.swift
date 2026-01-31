import Accelerate
import Foundation
import GRDB
import OSLog

/// Orchestrates the full story-theme clustering pipeline:
/// 1. Compute node DF/IDF weights
/// 2. Build event vectors
/// 3. Run HDBSCAN clustering
/// 4. Build and persist cluster artifacts (centroids, top entities, exemplars, labels)
final class ClusteringService: Sendable {

    /// Status update during the clustering pipeline.
    typealias StatusCallback = @MainActor @Sendable (String) -> Void

    /// Progress update with fraction complete (0..1).
    typealias ProgressCallback = @MainActor @Sendable (Double) -> Void

    private let database = Database.shared
    private let eventVectorService = EventVectorService()
    private let hdbscanService = HDBSCANService()
    private let clusterLabelingService = ClusterLabelingService()
    private let logger = Logger(subsystem: "com.newscomb", category: "ClusteringService")

    // MARK: - Full Pipeline

    /// Runs the complete clustering pipeline end-to-end.
    ///
    /// - Parameters:
    ///   - minClusterSize: Minimum points for a cluster (default 20).
    ///   - minSamples: Core distance neighborhood size (default 10).
    ///   - statusCallback: Human-readable status updates.
    ///   - progressCallback: Fractional progress updates.
    /// - Returns: The `buildId` of the completed clustering run.
    @discardableResult
    func runFullPipeline(
        minClusterSize: Int = 20,
        minSamples: Int = 10,
        statusCallback: StatusCallback? = nil,
        progressCallback: ProgressCallback? = nil
    ) async throws -> String {
        let buildId = UUID().uuidString
        logger.info("Starting clustering pipeline, build_id=\(buildId)")

        // Step 1: Compute IDF weights
        await statusCallback?("Computing IDF weights\u{2026}")
        await progressCallback?(0.05)
        try eventVectorService.computeIDFWeights()
        logger.info("IDF weights computed")

        // Step 2: Build event vectors
        await statusCallback?("Building event vectors\u{2026}")
        await progressCallback?(0.1)
        try await eventVectorService.buildEventVectors { status in
            statusCallback?(status)
        }
        logger.info("Event vectors built")

        // Step 3: Load vectors and run HDBSCAN
        await statusCallback?("Loading event vectors\u{2026}")
        await progressCallback?(0.35)
        let (eventIds, vectors) = try loadEventVectors()

        guard !vectors.isEmpty else {
            logger.warning("No event vectors available for clustering")
            throw ClusteringError.noVectors
        }

        await statusCallback?("Running HDBSCAN clustering (\(vectors.count) events)\u{2026}")
        await progressCallback?(0.45)

        let params = HDBSCANService.Parameters(
            minClusterSize: minClusterSize,
            minSamples: minSamples
        )
        let result = hdbscanService.cluster(vectors: vectors, params: params)
        logger.info("HDBSCAN complete: \(result.clusterCount) clusters found")

        // Step 4: Persist assignments
        await statusCallback?("Saving cluster assignments\u{2026}")
        await progressCallback?(0.6)
        try clearPreviousBuild()
        try persistAssignments(
            eventIds: eventIds,
            labels: result.labels,
            memberships: result.memberships,
            buildId: buildId
        )

        // Step 5: Build cluster artifacts
        await statusCallback?("Computing cluster metadata\u{2026}")
        await progressCallback?(0.7)
        try buildClusterArtifacts(
            eventIds: eventIds,
            vectors: vectors,
            labels: result.labels,
            memberships: result.memberships,
            buildId: buildId
        )

        // Step 6: LLM-generate cluster titles and summaries
        await statusCallback?("Generating theme summaries\u{2026}")
        await progressCallback?(0.85)
        await clusterLabelingService.labelClusters(
            buildId: buildId,
            statusCallback: statusCallback,
            progressCallback: { fraction in
                progressCallback?(0.85 + fraction * 0.14)
            }
        )

        await statusCallback?("Clustering complete")
        await progressCallback?(1.0)

        logger.info("Clustering pipeline complete: \(result.clusterCount) themes found")
        return buildId
    }

    // MARK: - Data Loading

    /// Loads all event vectors from the database.
    private func loadEventVectors() throws -> (eventIds: [Int64], vectors: [[Float]]) {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT event_id, vec FROM event_vectors ORDER BY event_id
            """)

            var eventIds: [Int64] = []
            var vectors: [[Float]] = []

            for row in rows {
                let eventId: Int64 = row["event_id"]
                let data: Data = row["vec"]
                let floats = data.withUnsafeBytes { buffer in
                    Array(buffer.bindMemory(to: Float.self))
                }
                guard floats.count == eventVectorService.eventVecDim else { continue }
                eventIds.append(eventId)
                vectors.append(floats)
            }

            return (eventIds, vectors)
        }
    }

    // MARK: - Persistence

    /// Clears all tables from the previous clustering build.
    private func clearPreviousBuild() throws {
        try database.write { db in
            try db.execute(sql: "DELETE FROM cluster_exemplars")
            try db.execute(sql: "DELETE FROM cluster_members")
            try db.execute(sql: "DELETE FROM event_cluster")
            try db.execute(sql: "DELETE FROM clusters")
        }
    }

    /// Persists cluster assignments to `event_cluster`.
    ///
    /// `cluster_members` is populated later in `buildClusterArtifacts` after the
    /// parent `clusters` rows exist (required by the foreign key constraint).
    private func persistAssignments(
        eventIds: [Int64],
        labels: [Int],
        memberships: [Double],
        buildId: String
    ) throws {
        try database.write { db in
            for (i, eventId) in eventIds.enumerated() {
                let clusterId = labels[i]
                let membership = memberships[i]

                // event_cluster — every event gets a row (noise = cluster_id -1)
                try db.execute(
                    sql: """
                        INSERT INTO event_cluster (event_id, build_id, cluster_id, membership)
                        VALUES (?, ?, ?, ?)
                    """,
                    arguments: [eventId, buildId, clusterId, membership]
                )
            }
        }
    }

    // MARK: - Cluster Artifacts

    /// Builds cluster metadata: centroids, top entities, exemplars, and auto-labels.
    private func buildClusterArtifacts(
        eventIds: [Int64],
        vectors: [[Float]],
        labels: [Int],
        memberships: [Double],
        buildId: String
    ) throws {
        // Group events by cluster
        var clusterEvents: [Int: [(index: Int, eventId: Int64, membership: Double)]] = [:]
        for (i, label) in labels.enumerated() where label >= 0 {
            clusterEvents[label, default: []].append((i, eventIds[i], memberships[i]))
        }

        // Load node labels for top entity computation
        let nodeLabels = try loadNodeLabels()
        let nodeIDFs = try loadNodeIDFs()

        for (clusterId, events) in clusterEvents {
            let memberVectors = events.map { vectors[$0.index] }
            let memberEventIds = events.map { $0.eventId }

            // Compute centroid
            let centroid = computeCentroid(memberVectors)
            let centroidData = centroid.withUnsafeBufferPointer { Data(buffer: $0) }

            // Find top entities
            let topEntities = try computeTopEntities(
                eventIds: memberEventIds,
                nodeLabels: nodeLabels,
                nodeIDFs: nodeIDFs,
                topK: 20
            )

            // Find top relation families
            let topFamilies = try computeTopRelFamilies(eventIds: memberEventIds, topK: 5)

            // Auto-label
            let label = autoLabel(topEntities: topEntities, topFamilies: topFamilies)

            // Encode JSON
            let entitiesJson = try String(data: JSONEncoder().encode(topEntities), encoding: .utf8)
            let familiesJson = try String(data: JSONEncoder().encode(topFamilies), encoding: .utf8)

            // Insert cluster row, then its members (FK requires cluster to exist first)
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO clusters (cluster_id, build_id, label, size, centroid_vec,
                                              top_entities_json, top_rel_families_json)
                        VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        clusterId, buildId, label, events.count,
                        centroidData, entitiesJson, familiesJson,
                    ]
                )

                for event in events {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO cluster_members (cluster_id, event_id, membership)
                            VALUES (?, ?, ?)
                        """,
                        arguments: [clusterId, event.eventId, event.membership]
                    )
                }
            }

            // Compute and persist exemplars (top 10 by cosine similarity to centroid)
            let exemplarIds = selectExemplars(
                eventIds: memberEventIds,
                vectors: memberVectors,
                centroid: centroid,
                topN: 10
            )

            try database.write { db in
                for (rank, eventId) in exemplarIds.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO cluster_exemplars (cluster_id, event_id, rank)
                            VALUES (?, ?, ?)
                        """,
                        arguments: [clusterId, eventId, rank]
                    )
                }
            }
        }

        logger.info("Built artifacts for \(clusterEvents.count) clusters")
    }

    /// Computes the centroid (mean vector) for a set of vectors using Accelerate.
    private func computeCentroid(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        let dim = first.count

        var sum = [Float](repeating: 0, count: dim)
        for vec in vectors {
            vDSP_vadd(sum, 1, vec, 1, &sum, 1, vDSP_Length(dim))
        }

        var scale = 1.0 / Float(vectors.count)
        vDSP_vsmul(sum, 1, &scale, &sum, 1, vDSP_Length(dim))

        return AccelerateVectorOps.normalize(sum)
    }

    /// Selects the top-N exemplar events by cosine similarity to the centroid.
    private func selectExemplars(
        eventIds: [Int64],
        vectors: [[Float]],
        centroid: [Float],
        topN: Int
    ) -> [Int64] {
        let similarities = vectors.enumerated().map { (i, vec) in
            (eventId: eventIds[i], similarity: AccelerateVectorOps.cosineSimilarity(centroid, vec))
        }

        return similarities
            .sorted { $0.similarity > $1.similarity }
            .prefix(topN)
            .map { $0.eventId }
    }

    /// Computes top entities across the cluster's events, weighted by IDF.
    private func computeTopEntities(
        eventIds: [Int64],
        nodeLabels: [Int64: String],
        nodeIDFs: [Int64: Double],
        topK: Int
    ) throws -> [RankedEntity] {
        try database.read { db in
            let placeholders = eventIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT node_id
                    FROM hypergraph_incidence
                    WHERE edge_id IN (\(placeholders))
                """,
                arguments: StatementArguments(eventIds)
            )

            // Count occurrences weighted by IDF
            var entityScores: [String: Double] = [:]
            for row in rows {
                let nodeId: Int64 = row["node_id"]
                guard let label = nodeLabels[nodeId] else { continue }
                let idf = nodeIDFs[nodeId] ?? 1.0
                entityScores[label, default: 0] += idf
            }

            return entityScores
                .map { RankedEntity(label: $0.key, score: $0.value) }
                .sorted { $0.score > $1.score }
                .prefix(topK)
                .map { $0 }
        }
    }

    /// Computes top relation families in the cluster by frequency.
    private func computeTopRelFamilies(eventIds: [Int64], topK: Int) throws -> [RankedFamily] {
        try database.read { db in
            let placeholders = eventIds.map { _ in "?" }.joined(separator: ",")
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT label FROM hypergraph_edge
                    WHERE id IN (\(placeholders))
                """,
                arguments: StatementArguments(eventIds)
            )

            var familyCounts: [String: Int] = [:]
            for row in rows {
                let verb: String = row["label"]
                let family = RelationFamily.classify(verb)
                familyCounts[family.label, default: 0] += 1
            }

            return familyCounts
                .map { RankedFamily(family: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }
                .prefix(topK)
                .map { $0 }
        }
    }

    /// Generates an auto-label for a cluster from its top entities and relation families.
    private func autoLabel(topEntities: [RankedEntity], topFamilies: [RankedFamily]) -> String {
        let entityPart = topEntities.prefix(2).map(\.label).joined(separator: ", ")
        let familyPart = topFamilies.first?.family

        if let familyPart, !entityPart.isEmpty {
            return "\(entityPart) \u{2014} \(familyPart)"
        } else if !entityPart.isEmpty {
            return entityPart
        } else {
            return "Cluster"
        }
    }

    // MARK: - Helpers

    private func loadNodeLabels() throws -> [Int64: String] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, label FROM hypergraph_node")
            var labels: [Int64: String] = [:]
            for row in rows {
                labels[row["id"]] = row["label"]
            }
            return labels
        }
    }

    private func loadNodeIDFs() throws -> [Int64: Double] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT id, COALESCE(idf, 1.0) as idf FROM hypergraph_node")
            var idfs: [Int64: Double] = [:]
            for row in rows {
                idfs[row["id"]] = row["idf"]
            }
            return idfs
        }
    }
}

// MARK: - Errors

enum ClusteringError: Error, LocalizedError {
    case noVectors
    case pipelineFailed(String)

    var errorDescription: String? {
        switch self {
        case .noVectors:
            return "No event vectors available. Ensure articles have been processed and node embeddings exist."
        case .pipelineFailed(let message):
            return "Clustering pipeline failed: \(message)"
        }
    }
}
