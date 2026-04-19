import Accelerate
import Foundation
import GRDB
import OSLog

/// Orchestrates the full story-theme clustering pipeline:
/// 1. Compute node DF/IDF weights
/// 2. Build event vectors
/// 3. PCA dimensionality reduction (2316D → ~50D)
/// 4. UMAP nonlinear embedding (~50D → ~25D)
/// 5. HDBSCAN density clustering on the reduced vectors
/// 6. Build and persist cluster artifacts (centroids, top entities, exemplars, labels)
final class ClusteringService: Sendable {

    /// Status update during the clustering pipeline.
    typealias StatusCallback = @MainActor @Sendable (String) -> Void

    /// Progress update with fraction complete (0..1).
    typealias ProgressCallback = @MainActor @Sendable (Double) -> Void

    private let database = Database.shared
    private let eventVectorService = EventVectorService()
    private let pcaService = PCAService()
    private let umapService = UMAPService()
    private let vpTreeService = VPTreeService()
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

        // Step 3: Load vectors
        await statusCallback?("Loading event vectors\u{2026}")
        await progressCallback?(0.35)
        let (eventIds, vectors) = try loadEventVectors()

        guard !vectors.isEmpty else {
            logger.warning("No event vectors available for clustering")
            throw ClusteringError.noVectors
        }

        // Step 3a: PCA dimensionality reduction
        let pcaTargetDim = loadIntSetting(AppSettings.pcaIntermediateDimension,
                                          default: AppSettings.defaultPCAIntermediateDimension)
        let inputDim = vectors[0].count
        let pcaReduced: [[Float]]
        if inputDim > pcaTargetDim {
            await statusCallback?("PCA: \(inputDim)D → \(pcaTargetDim)D\u{2026}")
            await progressCallback?(0.38)
            let pcaParams = PCAService.Parameters(targetDimension: pcaTargetDim)
            let pcaResult = pcaService.project(vectors: vectors, params: pcaParams)
            pcaReduced = pcaResult.projectedVectors
            let variancePct = (pcaResult.explainedVarianceRatio * 100).formatted(.number.precision(.fractionLength(1)))
            logger.info("PCA: \(inputDim)D → \(pcaTargetDim)D (explained variance: \(variancePct)%)")
        } else {
            pcaReduced = vectors
            logger.info("Skipping PCA: input dimension (\(inputDim)) <= target (\(pcaTargetDim))")
        }

        // Step 3b: UMAP nonlinear embedding
        let umapTargetDim = loadIntSetting(AppSettings.umapTargetDimension,
                                           default: AppSettings.defaultUMAPTargetDimension)
        let umapNeighbors = loadIntSetting(AppSettings.umapNNeighbors,
                                           default: AppSettings.defaultUMAPNNeighbors)
        let umapReduced: [[Float]]
        if pcaReduced[0].count > umapTargetDim && pcaReduced.count > umapNeighbors {
            await statusCallback?("UMAP: \(pcaReduced[0].count)D → \(umapTargetDim)D (\(pcaReduced.count) events)\u{2026}")
            await progressCallback?(0.42)
            let umapParams = UMAPService.Parameters(
                targetDimension: umapTargetDim,
                nNeighbors: umapNeighbors
            )
            // Surface SGD epoch progress to the UI without spamming on every epoch.
            let inDimDesc = pcaReduced[0].count
            let nDesc = pcaReduced.count
            umapReduced = try await umapService.reduce(
                vectors: pcaReduced,
                params: umapParams,
                progressCallback: { [statusCallback, progressCallback] epoch, total in
                    guard total > 0 else { return }
                    let stride = max(1, total / 20)
                    guard epoch == total || epoch % stride == 0 else { return }
                    let fraction = Double(epoch) / Double(total)
                    Task { @MainActor in
                        statusCallback?("UMAP SGD: epoch \(epoch)/\(total) (\(nDesc) events, \(inDimDesc)D → \(umapTargetDim)D)\u{2026}")
                        progressCallback?(0.42 + fraction * 0.06)
                    }
                }
            )
            logger.info("UMAP: \(pcaReduced[0].count)D → \(umapTargetDim)D")
        } else {
            umapReduced = pcaReduced
            logger.info("Skipping UMAP: dimension (\(pcaReduced[0].count)) <= target (\(umapTargetDim)) or too few points")
        }

        // Step 4: Run HDBSCAN on reduced vectors.
        // Compute kNN on the UMAP embedding for sparse HDBSCAN — avoids the
        // N² distance matrix that would OOM at 89K vectors (128 GB).
        await statusCallback?("Computing kNN for HDBSCAN (\(umapReduced.count) events, \(umapReduced[0].count)D)\u{2026}")
        await progressCallback?(0.50)

        let hdbscanParams = HDBSCANService.Parameters(
            minClusterSize: minClusterSize,
            minSamples: minSamples
        )
        let validatedParams = hdbscanParams.validated(forDataSize: umapReduced.count)
        // kNN k must be at least minSamples for core distance computation
        let hdbscanK = max(validatedParams.minSamples, umapNeighbors)
        let hdbscanKNN = await vpTreeService.findAllKNN(
            vectors: umapReduced, k: hdbscanK, metric: .cosine
        )

        await statusCallback?("Running HDBSCAN clustering (\(vectors.count) events, \(umapReduced[0].count)D)\u{2026}")
        await progressCallback?(0.55)

        let result = hdbscanService.clusterWithKNN(
            knn: hdbscanKNN, vectors: umapReduced, params: hdbscanParams
        )
        logger.info("HDBSCAN complete: \(result.clusterCount) clusters found")

        // Step 5: Persist assignments
        await statusCallback?("Saving cluster assignments\u{2026}")
        await progressCallback?(0.6)
        try clearPreviousBuild()
        try persistAssignments(
            eventIds: eventIds,
            labels: result.labels,
            memberships: result.memberships,
            buildId: buildId
        )

        // Step 6: Build cluster artifacts
        await statusCallback?("Computing cluster metadata\u{2026}")
        await progressCallback?(0.7)
        try buildClusterArtifacts(
            eventIds: eventIds,
            vectors: vectors,
            labels: result.labels,
            memberships: result.memberships,
            buildId: buildId
        )

        // Step 6b: Merge similar clusters by centroid proximity
        await statusCallback?("Merging similar clusters\u{2026}")
        await progressCallback?(0.75)
        let mergedCount = try mergeSimilarClusters(buildId: buildId, similarityThreshold: 0.85)
        if mergedCount > 0 {
            logger.info("Merged \(mergedCount) cluster pairs by centroid similarity")
        }

        // Step 7: LLM-generate cluster titles and summaries
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

    // MARK: - Cluster Merging

    /// Merges clusters whose centroids are above a cosine similarity threshold.
    ///
    /// After HDBSCAN, related topics can get fragmented into multiple small clusters
    /// (e.g., 13 separate "Paul Graham" clusters). This pass consolidates them by
    /// merging the smaller cluster into the larger one when their centroids are similar.
    ///
    /// - Returns: The number of cluster pairs merged.
    @discardableResult
    private func mergeSimilarClusters(buildId: String, similarityThreshold: Float) throws -> Int {
        // Load all cluster centroids
        let clusters: [(clusterId: Int64, size: Int, centroid: [Float])] = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT cluster_id, size, centroid_vec
                FROM clusters WHERE build_id = ? AND centroid_vec IS NOT NULL
                ORDER BY size DESC
            """, arguments: [buildId]).compactMap { row in
                guard let clusterId: Int64 = row["cluster_id"],
                      let size: Int = row["size"],
                      let data: Data = row["centroid_vec"] else { return nil }
                let centroid = data.withUnsafeBytes { buf in
                    Array(buf.bindMemory(to: Float.self))
                }
                guard !centroid.isEmpty else { return nil }
                return (clusterId, size, centroid)
            }
        }

        guard clusters.count >= 2 else { return 0 }

        // Find merge pairs: for each cluster, check if a larger cluster has
        // a similar centroid. Greedy: merge into the largest similar cluster.
        var merged = Set<Int64>()
        var mergeMap: [Int64: Int64] = [:] // small → large

        for i in 0..<clusters.count {
            let small = clusters[i]
            if merged.contains(small.clusterId) { continue }

            for j in 0..<i {
                let large = clusters[j]
                if merged.contains(large.clusterId) { continue }

                let similarity = AccelerateVectorOps.cosineSimilarity(small.centroid, large.centroid)
                if similarity >= similarityThreshold {
                    mergeMap[small.clusterId] = large.clusterId
                    merged.insert(small.clusterId)
                    break // merge into the first (largest) match
                }
            }
        }

        guard !mergeMap.isEmpty else { return 0 }

        // Apply merges in the database
        try database.write { db in
            for (smallId, largeId) in mergeMap {
                // Move members
                try db.execute(sql: """
                    UPDATE OR IGNORE cluster_members SET cluster_id = ? WHERE cluster_id = ?
                """, arguments: [largeId, smallId])

                // Move event_cluster assignments
                try db.execute(sql: """
                    UPDATE event_cluster SET cluster_id = ? WHERE cluster_id = ? AND build_id = ?
                """, arguments: [largeId, smallId, buildId])

                // Update size on the target cluster
                try db.execute(sql: """
                    UPDATE clusters SET size = (
                        SELECT COUNT(*) FROM cluster_members WHERE cluster_id = ?
                    ) WHERE cluster_id = ?
                """, arguments: [largeId, largeId])

                // Delete the merged cluster (cascades exemplars via FK)
                try db.execute(sql: "DELETE FROM clusters WHERE cluster_id = ?", arguments: [smallId])
            }

            // Recompute top entities and exemplars for merged clusters
            // (they'll be rebuilt during the next labeling pass via the existing data)
        }

        logger.info("Merged \(mergeMap.count) clusters (threshold: \(similarityThreshold))")
        return mergeMap.count
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
        // Accumulate node scores in Swift using batched queries to avoid
        // exceeding SQLite's SQLITE_MAX_VARIABLE_NUMBER limit.
        var entityScores: [String: Double] = [:]

        try database.read { db in
            for batch in eventIds.chunked(into: 500) {
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT node_id
                        FROM hypergraph_incidence
                        WHERE edge_id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(batch)
                )

                for row in rows {
                    let nodeId: Int64 = row["node_id"]
                    guard let label = nodeLabels[nodeId] else { continue }
                    let idf = nodeIDFs[nodeId] ?? 1.0
                    entityScores[label, default: 0] += idf
                }
            }
        }

        return entityScores
            .map { RankedEntity(label: $0.key, score: $0.value) }
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { $0 }
    }

    /// Computes top relation families in the cluster by frequency.
    private func computeTopRelFamilies(eventIds: [Int64], topK: Int) throws -> [RankedFamily] {
        var familyCounts: [String: Int] = [:]

        try database.read { db in
            for batch in eventIds.chunked(into: 500) {
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT label FROM hypergraph_edge
                        WHERE id IN (\(placeholders))
                    """,
                    arguments: StatementArguments(batch)
                )

                for row in rows {
                    let verb: String = row["label"]
                    let family = RelationFamily.classify(verb)
                    familyCounts[family.label, default: 0] += 1
                }
            }
        }

        return familyCounts
            .map { RankedFamily(family: $0.key, count: $0.value) }
            .sorted { $0.count > $1.count }
            .prefix(topK)
            .map { $0 }
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

    /// Reads an integer setting from the database, returning a default if not found.
    private func loadIntSetting(_ key: String, default defaultValue: Int) -> Int {
        do {
            return try database.read { db in
                if let setting = try AppSettings
                    .filter(AppSettings.Columns.key == key)
                    .fetchOne(db),
                   let value = Int(setting.value) {
                    return value
                }
                return defaultValue
            }
        } catch {
            return defaultValue
        }
    }

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
