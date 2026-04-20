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
    @concurrent
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

        // Read HDBSCAN settings; override defaults only when caller did not pass explicit values.
        let settingsMinClusterSize = loadIntSetting(AppSettings.hdbscanMinClusterSize,
                                                   default: AppSettings.defaultHDBSCANMinClusterSize)
        let settingsMinSamples = loadIntSetting(AppSettings.hdbscanMinSamples,
                                                default: AppSettings.defaultHDBSCANMinSamples)
        // 0 means "auto" — fall back to the function arg (which is already 20 by default).
        let effectiveMinClusterSize = settingsMinClusterSize > 0 ? settingsMinClusterSize : minClusterSize
        let effectiveMinSamples = settingsMinSamples > 0 ? settingsMinSamples : minSamples

        let hdbscanParams = HDBSCANService.Parameters(
            minClusterSize: effectiveMinClusterSize,
            minSamples: effectiveMinSamples
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
        let mergeThreshold = loadFloatSetting(AppSettings.clusterMergeThreshold,
                                              default: AppSettings.defaultClusterMergeThreshold)
        let mergedCount = try mergeSimilarClusters(buildId: buildId, similarityThreshold: mergeThreshold)
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

    // MARK: - Single-Cluster Split

    /// Result of attempting to split a single cluster into sub-clusters.
    struct SplitResult: Sendable {
        /// The cluster ID that was split.
        let originalClusterId: Int64
        /// New sub-cluster IDs and sizes (id is nil in dry-run mode).
        let newClusterSizes: [(id: Int64?, size: Int)]
        /// Member events that didn't fit any sub-cluster (HDBSCAN noise during the
        /// sub-clustering pass). They remain attached to the parent — splitting is
        /// non-destructive — but you may want to drop them by deleting the parent later.
        let unfittedCount: Int
        /// True if HDBSCAN returned 0 or 1 cluster — no split applied.
        let unchanged: Bool
        /// True if this was a dry run; no DB writes occurred.
        let dryRun: Bool
    }

    /// Re-clusters a single existing cluster's members to surface its sub-structure.
    ///
    /// **Non-destructive**: the parent cluster is left intact. Discovered sub-clusters are
    /// inserted as new rows with `parent_cluster_id = clusterId` and `is_tentative = 1`,
    /// alongside their `cluster_members` and `cluster_exemplars`. The parent's
    /// `event_cluster` rows are not touched — events stay attached to the parent.
    ///
    /// Use `saveSplit()` to promote tentative children to permanent sub-themes, or
    /// `discardSplit()` to remove them.
    ///
    /// - Parameters:
    ///   - clusterId: ID of the cluster to split.
    ///   - minClusterSizeOverride: Optional HDBSCAN min cluster size. If nil, uses sqrt(N)/4 of member count.
    ///   - minSamplesOverride: Optional HDBSCAN min samples. If nil, uses the app setting.
    ///   - relabel: Whether to LLM-label the new sub-clusters. Ignored when `dryRun` is true.
    ///   - dryRun: If true, return predicted sizes without writing anything to the database.
    @discardableResult
    @concurrent
    func splitCluster(
        clusterId: Int64,
        minClusterSizeOverride: Int? = nil,
        minSamplesOverride: Int? = nil,
        relabel: Bool = true,
        dryRun: Bool = false,
        statusCallback: StatusCallback? = nil,
        progressCallback: ProgressCallback? = nil
    ) async throws -> SplitResult {
        logger.info("Splitting cluster \(clusterId), dryRun=\(dryRun)")

        // Step 1: Resolve the build_id and member event_ids.
        await statusCallback?("Loading cluster members\u{2026}")
        await progressCallback?(0.05)
        let (buildId, memberEventIds) = try database.read { db -> (String, [Int64]) in
            guard let buildId = try String.fetchOne(
                db,
                sql: "SELECT build_id FROM clusters WHERE cluster_id = ?",
                arguments: [clusterId]
            ) else {
                throw ClusteringError.pipelineFailed("Cluster \(clusterId) not found")
            }
            let eventIds = try Int64.fetchAll(
                db,
                sql: "SELECT event_id FROM cluster_members WHERE cluster_id = ? ORDER BY event_id",
                arguments: [clusterId]
            )
            return (buildId, eventIds)
        }

        guard memberEventIds.count >= 4 else {
            throw ClusteringError.pipelineFailed("Cluster \(clusterId) has only \(memberEventIds.count) members — too few to split")
        }

        // Step 2: Load vectors for those members.
        await statusCallback?("Loading \(memberEventIds.count) event vectors\u{2026}")
        await progressCallback?(0.10)
        let (eventIds, vectors) = try loadEventVectors(filterEventIds: memberEventIds)
        guard vectors.count == memberEventIds.count else {
            throw ClusteringError.pipelineFailed("Loaded \(vectors.count) vectors but expected \(memberEventIds.count)")
        }

        // Step 3: PCA reduction (reuse the user's settings).
        let pcaTargetDim = loadIntSetting(AppSettings.pcaIntermediateDimension,
                                          default: AppSettings.defaultPCAIntermediateDimension)
        let inputDim = vectors[0].count
        let pcaReduced: [[Float]]
        if inputDim > pcaTargetDim {
            await statusCallback?("PCA: \(inputDim)D → \(pcaTargetDim)D\u{2026}")
            await progressCallback?(0.20)
            let pcaParams = PCAService.Parameters(targetDimension: pcaTargetDim)
            pcaReduced = pcaService.project(vectors: vectors, params: pcaParams).projectedVectors
        } else {
            pcaReduced = vectors
        }

        // Step 4: UMAP nonlinear embedding (skip if cluster is already small enough).
        let umapTargetDim = loadIntSetting(AppSettings.umapTargetDimension,
                                           default: AppSettings.defaultUMAPTargetDimension)
        let umapNeighbors = loadIntSetting(AppSettings.umapNNeighbors,
                                           default: AppSettings.defaultUMAPNNeighbors)
        let umapReduced: [[Float]]
        if pcaReduced[0].count > umapTargetDim && pcaReduced.count > umapNeighbors {
            await statusCallback?("UMAP: \(pcaReduced[0].count)D → \(umapTargetDim)D\u{2026}")
            await progressCallback?(0.35)
            let umapParams = UMAPService.Parameters(targetDimension: umapTargetDim, nNeighbors: umapNeighbors)
            umapReduced = try await umapService.reduce(vectors: pcaReduced, params: umapParams, progressCallback: nil)
        } else {
            umapReduced = pcaReduced
        }

        // Step 5: HDBSCAN with split-specific defaults — more aggressive than the global pipeline.
        // sqrt(N)/4 (vs sqrt(N)/2 in the global heuristic) so splits actually fragment the cluster.
        let n = umapReduced.count
        let defaultSplitMinClusterSize = max(20, Int(Double(n).squareRoot() / 4))
        let settingsMinSamples = loadIntSetting(AppSettings.hdbscanMinSamples,
                                                default: AppSettings.defaultHDBSCANMinSamples)
        let effectiveMinClusterSize = minClusterSizeOverride ?? defaultSplitMinClusterSize
        let effectiveMinSamples = minSamplesOverride ?? settingsMinSamples
        let hdbscanParams = HDBSCANService.Parameters(
            minClusterSize: effectiveMinClusterSize,
            minSamples: effectiveMinSamples
        )

        await statusCallback?("Computing kNN (\(n) events)\u{2026}")
        await progressCallback?(0.55)
        let validatedParams = hdbscanParams.validated(forDataSize: n)
        let hdbscanK = max(validatedParams.minSamples, umapNeighbors)
        let knn = await vpTreeService.findAllKNN(vectors: umapReduced, k: hdbscanK, metric: .cosine)

        await statusCallback?("Running HDBSCAN on \(n) events\u{2026}")
        await progressCallback?(0.65)
        let result = hdbscanService.clusterWithKNN(knn: knn, vectors: umapReduced, params: hdbscanParams)
        logger.info("Split HDBSCAN: \(result.clusterCount) sub-clusters, \(result.labels.filter { $0 == -1 }.count) noise")

        // Group local labels (0..k-1) by sub-cluster, with noise (-1) handled separately.
        var localGroups: [Int: [(index: Int, eventId: Int64, membership: Double)]] = [:]
        var noiseEventIds: [Int64] = []
        for (i, label) in result.labels.enumerated() {
            if label < 0 {
                noiseEventIds.append(eventIds[i])
            } else {
                localGroups[label, default: []].append((i, eventIds[i], result.memberships[i]))
            }
        }

        // Step 6: Guard — nothing to split.
        guard result.clusterCount >= 2 else {
            await statusCallback?("Split produced \(result.clusterCount) sub-cluster(s) — no change")
            await progressCallback?(1.0)
            return SplitResult(
                originalClusterId: clusterId,
                newClusterSizes: localGroups.values.map { (id: nil, size: $0.count) },
                unfittedCount: noiseEventIds.count,
                unchanged: true,
                dryRun: dryRun
            )
        }

        // Step 7: Dry-run short-circuit — no DB writes.
        if dryRun {
            await statusCallback?("Dry run complete")
            await progressCallback?(1.0)
            let sizes = localGroups.values
                .map { (id: Int64?.none, size: $0.count) }
                .sorted { $0.size > $1.size }
            return SplitResult(
                originalClusterId: clusterId,
                newClusterSizes: sizes,
                unfittedCount: noiseEventIds.count,
                unchanged: false,
                dryRun: true
            )
        }

        // Step 8: Allocate new cluster IDs after the current build's max.
        let nextId = try database.read { db -> Int64 in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(cluster_id), 0) + 1 FROM clusters WHERE build_id = ?",
                arguments: [buildId]
            ) ?? 1
        }
        let sortedLocalLabels = localGroups.keys.sorted { localGroups[$0]!.count > localGroups[$1]!.count }
        var localToGlobal: [Int: Int64] = [:]
        for (offset, localLabel) in sortedLocalLabels.enumerated() {
            localToGlobal[localLabel] = nextId + Int64(offset)
        }
        let newClusterIds = sortedLocalLabels.compactMap { localToGlobal[$0] }

        // Step 9: Compute artifacts for each new sub-cluster (centroid, top entities, exemplars, auto-label).
        let nodeLabels = try loadNodeLabels()
        let nodeIDFs = try loadNodeIDFs()

        struct NewClusterArtifact {
            let clusterId: Int64
            let members: [(eventId: Int64, membership: Double)]
            let centroidData: Data
            let entitiesJson: String?
            let familiesJson: String?
            let label: String
            let exemplarIds: [Int64]
        }

        var artifacts: [NewClusterArtifact] = []
        for localLabel in sortedLocalLabels {
            guard let group = localGroups[localLabel],
                  let newId = localToGlobal[localLabel] else { continue }
            let memberVectors = group.map { vectors[$0.index] }
            let memberIds = group.map { $0.eventId }
            let centroid = computeCentroid(memberVectors)
            let centroidData = centroid.withUnsafeBufferPointer { Data(buffer: $0) }

            let topEntities = try computeTopEntities(
                eventIds: memberIds, nodeLabels: nodeLabels, nodeIDFs: nodeIDFs, topK: 20
            )
            let topFamilies = try computeTopRelFamilies(eventIds: memberIds, topK: 5)
            let label = autoLabel(topEntities: topEntities, topFamilies: topFamilies)
            let entitiesJson = try String(data: JSONEncoder().encode(topEntities), encoding: .utf8)
            let familiesJson = try String(data: JSONEncoder().encode(topFamilies), encoding: .utf8)
            let exemplarIds = selectExemplars(
                eventIds: memberIds, vectors: memberVectors, centroid: centroid, topN: 10
            )

            artifacts.append(NewClusterArtifact(
                clusterId: newId,
                members: group.map { (eventId: $0.eventId, membership: $0.membership) },
                centroidData: centroidData,
                entitiesJson: entitiesJson,
                familiesJson: familiesJson,
                label: label,
                exemplarIds: exemplarIds
            ))
        }

        // Step 10: Non-destructive write — keep parent intact, insert tentative sub-clusters
        // pointing back to the parent. event_cluster is left alone (events stay attached to parent).
        // Save Split flips is_tentative to 0; Discard Split deletes these rows.
        await statusCallback?("Persisting \(artifacts.count) tentative sub-cluster(s)\u{2026}")
        await progressCallback?(0.85)
        try database.write { db in
            for art in artifacts {
                try db.execute(
                    sql: """
                        INSERT INTO clusters (cluster_id, build_id, label, size, centroid_vec,
                                              top_entities_json, top_rel_families_json,
                                              parent_cluster_id, is_tentative)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                    """,
                    arguments: [
                        art.clusterId, buildId, art.label, art.members.count,
                        art.centroidData, art.entitiesJson, art.familiesJson,
                        clusterId,
                    ]
                )

                for member in art.members {
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO cluster_members (cluster_id, event_id, membership)
                            VALUES (?, ?, ?)
                        """,
                        arguments: [art.clusterId, member.eventId, member.membership]
                    )
                }

                for (rank, eventId) in art.exemplarIds.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO cluster_exemplars (cluster_id, event_id, rank)
                            VALUES (?, ?, ?)
                        """,
                        arguments: [art.clusterId, eventId, rank]
                    )
                }
            }
        }

        // Step 11: Optional LLM relabel of just the new sub-clusters.
        if relabel {
            await statusCallback?("Generating sub-theme summaries\u{2026}")
            await progressCallback?(0.92)
            await clusterLabelingService.labelClusters(
                buildId: buildId,
                onlyClusterIds: Set(newClusterIds),
                statusCallback: statusCallback,
                progressCallback: { fraction in
                    progressCallback?(0.92 + fraction * 0.07)
                }
            )
        }

        await statusCallback?("Split complete")
        await progressCallback?(1.0)

        return SplitResult(
            originalClusterId: clusterId,
            newClusterSizes: artifacts.map { (id: Optional($0.clusterId), size: $0.members.count) },
            unfittedCount: noiseEventIds.count,
            unchanged: false,
            dryRun: false
        )
    }

    // MARK: - Noise-Pool Detection

    /// Result of running the IQR-on-log(size) outlier detector across the current
    /// top-level clusters.
    struct NoisePoolDetectionResult: Sendable {
        /// The log-size threshold computed from the data: `Q3 + multiplier * IQR`.
        /// Anything with `log(size)` strictly above this is flagged.
        let logSizeThreshold: Double
        /// Cluster IDs flagged as noise pools, sorted descending by size.
        let noisePoolClusterIds: [Int64]
    }

    /// Identifies "noise-pool" clusters — statistical outliers in cluster size that
    /// most likely represent absorption pools (everything HDBSCAN couldn't tightly
    /// group elsewhere) rather than real themes.
    ///
    /// Uses the standard Tukey IQR rule applied to `log(size)` so that the threshold
    /// adapts naturally to a heavy-tailed size distribution. Inputs with sizes ≤ 1
    /// (or fewer than 4 usable clusters) yield no outliers.
    ///
    /// - Parameters:
    ///   - sizes: top-level cluster (id, size) pairs.
    ///   - iqrMultiplier: outlier strictness; 1.5 is the standard Tukey rule.
    static func detectNoisePools(
        sizes: [(clusterId: Int64, size: Int)],
        iqrMultiplier: Float = 1.5
    ) -> NoisePoolDetectionResult {
        // Filter trivially-small clusters so they don't compress the IQR.
        let usable = sizes.filter { $0.size > 1 }
        // Need a meaningful sample to compute quartiles.
        guard usable.count >= 4 else {
            return NoisePoolDetectionResult(logSizeThreshold: .infinity, noisePoolClusterIds: [])
        }

        let logs = usable.map { log(Double($0.size)) }.sorted()
        let q1 = quantile(sortedAscending: logs, p: 0.25)
        let q3 = quantile(sortedAscending: logs, p: 0.75)
        let iqr = q3 - q1
        let threshold = q3 + Double(iqrMultiplier) * iqr

        let outliers = usable
            .filter { log(Double($0.size)) > threshold }
            .sorted { $0.size > $1.size }
            .map { $0.clusterId }

        return NoisePoolDetectionResult(logSizeThreshold: threshold, noisePoolClusterIds: outliers)
    }

    /// Linear-interpolated quantile on a pre-sorted ascending array.
    private static func quantile(sortedAscending sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return .nan }
        if sorted.count == 1 { return sorted[0] }
        let pos = p * Double(sorted.count - 1)
        let lower = Int(pos.rounded(.down))
        let upper = Int(pos.rounded(.up))
        if lower == upper { return sorted[lower] }
        let frac = pos - Double(lower)
        return sorted[lower] * (1 - frac) + sorted[upper] * frac
    }

    // MARK: - Focused Theme Extraction

    /// Result of extracting a focused theme from a parent cluster by phrase.
    struct ExtractResult: Sendable {
        let originalClusterId: Int64
        /// nil when `dryRun == true` (no row was written).
        let newClusterId: Int64?
        let matchedCount: Int
        /// Top similarity score (1 - distance) across matches, in [-1, 1]. 0 if no matches.
        let topSimilarityScore: Float
        let dryRun: Bool
    }

    /// Extracts events from a parent cluster that match a free-text phrase, using
    /// the same chunk-embedding semantic search path as the RAG pipeline.
    ///
    /// Non-destructive: the parent stays intact. Matched events become a new
    /// tentative sub-cluster (`is_tentative = 1`) under the parent, navigable like
    /// any other sub-theme. Save Split / Discard Split / Delete operate on it as usual.
    ///
    /// - Parameters:
    ///   - parentClusterId: Parent cluster to extract from.
    ///   - queryText: Free-text phrase, e.g. "Google Spanner BigQuery".
    ///   - topK: Maximum events to include (caps how big the result can get).
    ///   - similarityThreshold: Minimum cosine similarity (0..1) to include an event.
    ///   - relabel: Whether to LLM-label the new sub-cluster. Ignored when `dryRun` is true.
    ///   - dryRun: If true, return predicted match count without writing anything.
    @discardableResult
    @concurrent
    func extractTheme(
        parentClusterId: Int64,
        queryText: String,
        topK: Int = 200,
        similarityThreshold: Float = 0.45,
        relabel: Bool = true,
        dryRun: Bool = false,
        statusCallback: StatusCallback? = nil,
        progressCallback: ProgressCallback? = nil
    ) async throws -> ExtractResult {
        let trimmed = queryText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ClusteringError.pipelineFailed("Query text is empty")
        }

        logger.info("Extracting theme from cluster \(parentClusterId), query='\(trimmed, privacy: .public)', topK=\(topK), dryRun=\(dryRun)")

        // Step 1: Resolve build_id and member event_ids.
        await statusCallback?("Loading parent cluster\u{2026}")
        await progressCallback?(0.05)
        let (buildId, memberEventIds) = try database.read { db -> (String, [Int64]) in
            guard let buildId = try String.fetchOne(
                db,
                sql: "SELECT build_id FROM clusters WHERE cluster_id = ?",
                arguments: [parentClusterId]
            ) else {
                throw ClusteringError.pipelineFailed("Cluster \(parentClusterId) not found")
            }
            let eventIds = try Int64.fetchAll(
                db,
                sql: "SELECT event_id FROM cluster_members WHERE cluster_id = ? ORDER BY event_id",
                arguments: [parentClusterId]
            )
            return (buildId, eventIds)
        }

        guard !memberEventIds.isEmpty else {
            throw ClusteringError.pipelineFailed("Cluster \(parentClusterId) has no members to extract from")
        }

        // Step 2: Map each member event to its source chunk (events without a
        // chunk are dropped — they can't be ranked by text similarity).
        await statusCallback?("Linking \(memberEventIds.count) events to source chunks\u{2026}")
        await progressCallback?(0.10)
        let eventToChunk = try loadEventToChunkMap(eventIds: memberEventIds)
        let chunkCoverage = memberEventIds.isEmpty ? 0 : (Double(eventToChunk.count) * 100 / Double(memberEventIds.count))
        logger.info("extractTheme: \(eventToChunk.count)/\(memberEventIds.count) events have source chunks (\(String(format: "%.1f", chunkCoverage))%)")
        guard !eventToChunk.isEmpty else {
            // Surface as a graceful no-match rather than throwing — the user just sees a clear message.
            await statusCallback?("No member events have source chunks (extraction needs chunk text)")
            await progressCallback?(1.0)
            return ExtractResult(
                originalClusterId: parentClusterId,
                newClusterId: nil,
                matchedCount: 0,
                topSimilarityScore: 0,
                dryRun: dryRun
            )
        }

        // Step 3: Embed the query using the configured embedding provider
        // (must match what `chunk_embedding` was built with — same pattern as GraphRAGService).
        await statusCallback?("Embedding query phrase\u{2026}")
        await progressCallback?(0.20)
        let queryEmbedding = try await embedQuery(trimmed)
        let queryEmbeddingData = queryEmbedding.withUnsafeBufferPointer { Data(buffer: $0) }
        logger.info("extractTheme: query embedded to \(queryEmbedding.count) dims")

        // Step 4: Vector-search chunk_embedding limited to the parent's chunks,
        // batched to respect SQLite's variable limit. Collect (chunkId, distance) pairs.
        await statusCallback?("Scoring \(eventToChunk.count) chunk(s) against query\u{2026}")
        await progressCallback?(0.40)
        let chunkIds = Array(Set(eventToChunk.values))
        var allHits: [(chunkId: Int64, distance: Double)] = []
        var nullDistanceCount = 0
        try database.read { db in
            for batch in chunkIds.chunked(into: 500) {
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let sql = """
                    SELECT chunk_id, vec_distance_cosine(embedding, ?) AS distance
                    FROM chunk_embedding
                    WHERE chunk_id IN (\(placeholders))
                """
                var args: [DatabaseValueConvertible] = [queryEmbeddingData]
                args.append(contentsOf: batch.map { $0 as DatabaseValueConvertible })
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                for row in rows {
                    let chunkId: Int64 = row["chunk_id"]
                    // vec_distance_cosine returns NULL when the dimensions don't match; count those
                    // so we can warn the user rather than silently producing zero matches.
                    if let distance: Double = row["distance"] {
                        allHits.append((chunkId, distance))
                    } else {
                        nullDistanceCount += 1
                    }
                }
            }
        }
        allHits.sort { $0.distance < $1.distance }
        logger.info("extractTheme: scored \(allHits.count) chunks (\(nullDistanceCount) returned NULL distance — likely dim mismatch if non-zero)")

        if allHits.isEmpty && nullDistanceCount > 0 {
            await statusCallback?("Embedding dimension mismatch — chunk_embedding has \(nullDistanceCount) row(s) but vec_distance_cosine returned NULL")
            await progressCallback?(1.0)
            throw ClusteringError.pipelineFailed("Query embedding dimension does not match chunk_embedding dimension. Check Settings → Embedding provider matches the one used to build the graph.")
        }

        // Best-overall score across ALL hits (regardless of threshold) — surfaces in noMatches
        // so the user knows whether to lower the threshold.
        let bestScoreAcrossAll: Float = allHits.first.map { Float(1.0 - $0.distance) } ?? 0

        // Step 5: Apply threshold (similarity = 1 - distance) then top-K cap.
        let similarityCutoffDistance = Double(1.0 - similarityThreshold)
        let aboveThreshold = allHits.filter { $0.distance <= similarityCutoffDistance }
        let topHits = Array(aboveThreshold.prefix(topK))

        // Map chunk hits back to event_ids (a chunk could be the source of multiple events).
        let chunkToEvents: [Int64: [Int64]] = Dictionary(grouping: eventToChunk, by: { $0.value }).mapValues { $0.map(\.key) }
        var matchedEventIds: [Int64] = []
        var seen = Set<Int64>()
        for hit in topHits {
            for eventId in chunkToEvents[hit.chunkId] ?? [] {
                if seen.insert(eventId).inserted {
                    matchedEventIds.append(eventId)
                }
            }
        }

        // Step 6: Guard — nothing matched. Report the best score we saw across all hits
        // so the user knows whether to lower the threshold.
        guard !matchedEventIds.isEmpty else {
            await statusCallback?("No events above threshold \(similarityThreshold) (best was \(String(format: "%.3f", bestScoreAcrossAll)))")
            await progressCallback?(1.0)
            return ExtractResult(
                originalClusterId: parentClusterId,
                newClusterId: nil,
                matchedCount: 0,
                topSimilarityScore: bestScoreAcrossAll,
                dryRun: dryRun
            )
        }

        // Step 7: Dry-run short-circuit.
        if dryRun {
            await statusCallback?("Dry run complete")
            await progressCallback?(1.0)
            return ExtractResult(
                originalClusterId: parentClusterId,
                newClusterId: nil,
                matchedCount: matchedEventIds.count,
                topSimilarityScore: topHits.first.map { Float(1.0 - $0.distance) } ?? bestScoreAcrossAll,
                dryRun: true
            )
        }

        // Step 8: Compute artifacts. Need event vectors for centroid + exemplars.
        await statusCallback?("Computing artifacts for \(matchedEventIds.count) matched events\u{2026}")
        await progressCallback?(0.65)
        let (orderedEventIds, vectors) = try loadEventVectors(filterEventIds: matchedEventIds)
        let centroid = computeCentroid(vectors)
        let centroidData = centroid.withUnsafeBufferPointer { Data(buffer: $0) }
        let nodeLabels = try loadNodeLabels()
        let nodeIDFs = try loadNodeIDFs()
        let topEntities = try computeTopEntities(eventIds: orderedEventIds, nodeLabels: nodeLabels, nodeIDFs: nodeIDFs, topK: 20)
        let topFamilies = try computeTopRelFamilies(eventIds: orderedEventIds, topK: 5)
        let label = "\(trimmed) — \(autoLabel(topEntities: topEntities, topFamilies: topFamilies))"
        let entitiesJson = try String(data: JSONEncoder().encode(topEntities), encoding: .utf8)
        let familiesJson = try String(data: JSONEncoder().encode(topFamilies), encoding: .utf8)
        let exemplarIds = selectExemplars(eventIds: orderedEventIds, vectors: vectors, centroid: centroid, topN: 10)

        // Step 9: Allocate new cluster ID and persist as tentative child.
        await statusCallback?("Persisting tentative sub-theme\u{2026}")
        await progressCallback?(0.80)
        let newClusterId = try database.write { db -> Int64 in
            let nextId = try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(cluster_id), 0) + 1 FROM clusters WHERE build_id = ?",
                arguments: [buildId]
            ) ?? 1

            try db.execute(
                sql: """
                    INSERT INTO clusters (cluster_id, build_id, label, size, centroid_vec,
                                          top_entities_json, top_rel_families_json,
                                          parent_cluster_id, is_tentative)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
                """,
                arguments: [
                    nextId, buildId, label, orderedEventIds.count,
                    centroidData, entitiesJson, familiesJson,
                    parentClusterId,
                ]
            )
            for eventId in orderedEventIds {
                try db.execute(
                    sql: """
                        INSERT OR IGNORE INTO cluster_members (cluster_id, event_id, membership)
                        VALUES (?, ?, 1.0)
                    """,
                    arguments: [nextId, eventId]
                )
            }
            for (rank, eventId) in exemplarIds.enumerated() {
                try db.execute(
                    sql: """
                        INSERT INTO cluster_exemplars (cluster_id, event_id, rank)
                        VALUES (?, ?, ?)
                    """,
                    arguments: [nextId, eventId, rank]
                )
            }
            return nextId
        }

        // Step 10: Optional LLM relabel of the new sub-cluster.
        if relabel {
            await statusCallback?("Generating sub-theme summary\u{2026}")
            await progressCallback?(0.92)
            await clusterLabelingService.labelClusters(
                buildId: buildId,
                onlyClusterIds: [newClusterId],
                statusCallback: statusCallback,
                progressCallback: { fraction in
                    progressCallback?(0.92 + fraction * 0.07)
                }
            )
        }

        await statusCallback?("Extract complete")
        await progressCallback?(1.0)
        let finalTopScore: Float = topHits.first.map { Float(1.0 - $0.distance) } ?? bestScoreAcrossAll
        return ExtractResult(
            originalClusterId: parentClusterId,
            newClusterId: newClusterId,
            matchedCount: orderedEventIds.count,
            topSimilarityScore: finalTopScore,
            dryRun: false
        )
    }

    /// Loads `event_id → chunk_id` mapping for the given events, batched to respect
    /// SQLite's variable limit. Events without a `source_chunk_id` are omitted.
    private func loadEventToChunkMap(eventIds: [Int64]) throws -> [Int64: Int64] {
        var map: [Int64: Int64] = [:]
        try database.read { db in
            for batch in eventIds.chunked(into: 500) {
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: """
                        SELECT id AS event_id, source_chunk_id
                        FROM hypergraph_edge
                        WHERE id IN (\(placeholders)) AND source_chunk_id IS NOT NULL
                    """,
                    arguments: StatementArguments(batch)
                )
                for row in rows {
                    let eventId: Int64 = row["event_id"]
                    let chunkId: Int64 = row["source_chunk_id"]
                    map[eventId] = chunkId
                }
            }
        }
        return map
    }

    /// Embeds `text` using the configured embedding provider. Mirrors the pattern in
    /// `GraphRAGService.embedText` so the result is in the same vector space as the
    /// rows in `chunk_embedding`.
    private func embedQuery(_ text: String) async throws -> [Float] {
        // Read provider settings on the calling actor's serial DB queue.
        let providerInfo = try database.read { db -> (provider: String, openRouterModel: String, dimensions: Int, openRouterKey: String?) in
            let provider: String
            if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.embeddingProvider).fetchOne(db) {
                provider = setting.value == "ollama" ? "nomic" : setting.value
            } else {
                provider = AppSettings.defaultEmbeddingProvider
            }
            let openRouterModel = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingOpenRouterModel)
                .fetchOne(db)?.value ?? AppSettings.defaultEmbeddingOpenRouterModel
            let dimensions = try AppSettings.effectiveEmbeddingDimension(db)
            let key = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.openRouterKey)
                .fetchOne(db)?.value
            return (provider, openRouterModel, dimensions, key)
        }

        if providerInfo.provider == "openrouter" {
            guard let apiKey = providerInfo.openRouterKey, !apiKey.isEmpty else {
                throw ClusteringError.pipelineFailed("OpenRouter API key not configured")
            }
            let service = OpenRouterEmbeddingService(
                apiKey: apiKey,
                model: providerInfo.openRouterModel,
                dimensions: providerInfo.dimensions
            )
            return try await service.embed(text)
        } else {
            return try await NomicEmbeddingService.shared.embed(text)
        }
    }

    // MARK: - Save / Discard / Delete

    /// Outcome of `deleteCluster` describing how dependents were handled.
    struct DeleteResult: Sendable {
        /// Number of children whose `parent_cluster_id` was unlinked
        /// (set NULL via FK ON DELETE SET NULL) — includes both saved and formerly-tentative.
        let unlinkedChildCount: Int
        /// Number of tentative children that were promoted to regular standalone clusters
        /// (their `is_tentative` flag was cleared because they no longer have a parent
        /// to save/discard against).
        let promotedTentativeChildCount: Int
    }

    /// Promotes all tentative children of `parentClusterId` to permanent sub-themes.
    /// Returns the number of rows updated.
    @discardableResult
    @concurrent
    func saveSplit(parentClusterId: Int64) async throws -> Int {
        try database.write { db in
            try db.execute(
                sql: "UPDATE clusters SET is_tentative = 0 WHERE parent_cluster_id = ? AND is_tentative = 1",
                arguments: [parentClusterId]
            )
            return db.changesCount
        }
    }

    /// Deletes all tentative children of `parentClusterId`. Returns the number of rows removed.
    /// Cascade FKs clean up `cluster_members` and `cluster_exemplars` automatically.
    @discardableResult
    @concurrent
    func discardSplit(parentClusterId: Int64) async throws -> Int {
        try database.write { db in
            try db.execute(
                sql: "DELETE FROM clusters WHERE parent_cluster_id = ? AND is_tentative = 1",
                arguments: [parentClusterId]
            )
            return db.changesCount
        }
    }

    /// Deletes a single cluster row. Underlying graph data (nodes, edges, embeddings,
    /// chunks, articles) is preserved.
    ///
    /// - For a regular leaf cluster: removes its `event_cluster` rows then deletes it
    ///   (cascade removes `cluster_members` and `cluster_exemplars`).
    /// - For a parent cluster: ALL children (saved and tentative) are unlinked — their
    ///   `parent_cluster_id` is set to NULL automatically via the FK ON DELETE SET NULL,
    ///   so they become top-level themes. Tentative children also have their
    ///   `is_tentative` flag cleared first (since without a parent there's no
    ///   save/discard context they could participate in — they're now standalone themes).
    @discardableResult
    @concurrent
    func deleteCluster(_ clusterId: Int64) async throws -> DeleteResult {
        try database.write { db in
            // Count children for the result struct.
            let savedChildren = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clusters WHERE parent_cluster_id = ? AND is_tentative = 0",
                arguments: [clusterId]
            ) ?? 0
            let tentativeChildren = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clusters WHERE parent_cluster_id = ? AND is_tentative = 1",
                arguments: [clusterId]
            ) ?? 0

            // Promote tentative children to regular standalone clusters BEFORE the parent is
            // deleted. The FK ON DELETE SET NULL will then unlink all children (saved +
            // formerly-tentative) uniformly. Clearing is_tentative ensures the promoted
            // children don't linger as orphan "tentative" rows with no parent context.
            if tentativeChildren > 0 {
                try db.execute(
                    sql: "UPDATE clusters SET is_tentative = 0 WHERE parent_cluster_id = ? AND is_tentative = 1",
                    arguments: [clusterId]
                )
            }

            // event_cluster has no FK back to clusters — clean up explicitly.
            try db.execute(
                sql: "DELETE FROM event_cluster WHERE cluster_id = ?",
                arguments: [clusterId]
            )

            // Now delete the cluster itself. FK ON DELETE SET NULL on parent_cluster_id
            // unlinks all children automatically. FK ON DELETE CASCADE cleans up
            // cluster_members and cluster_exemplars.
            try db.execute(sql: "DELETE FROM clusters WHERE cluster_id = ?", arguments: [clusterId])

            return DeleteResult(
                unlinkedChildCount: savedChildren + tentativeChildren,
                promotedTentativeChildCount: tentativeChildren
            )
        }
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

    /// Loads event vectors restricted to the given event IDs, batched to respect SQLite's
    /// SQLITE_MAX_VARIABLE_NUMBER limit. Output is ordered by event_id ascending.
    private func loadEventVectors(filterEventIds: [Int64]) throws -> (eventIds: [Int64], vectors: [[Float]]) {
        guard !filterEventIds.isEmpty else { return ([], []) }
        return try database.read { db in
            var byId: [Int64: [Float]] = [:]
            for batch in filterEventIds.chunked(into: 500) {
                let placeholders = batch.map { _ in "?" }.joined(separator: ",")
                let rows = try Row.fetchAll(
                    db,
                    sql: "SELECT event_id, vec FROM event_vectors WHERE event_id IN (\(placeholders))",
                    arguments: StatementArguments(batch)
                )
                for row in rows {
                    let eventId: Int64 = row["event_id"]
                    let data: Data = row["vec"]
                    let floats = data.withUnsafeBytes { buffer in
                        Array(buffer.bindMemory(to: Float.self))
                    }
                    guard floats.count == eventVectorService.eventVecDim else { continue }
                    byId[eventId] = floats
                }
            }
            let sortedIds = byId.keys.sorted()
            let vectors = sortedIds.map { byId[$0]! }
            return (sortedIds, vectors)
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

    /// Reads a Float setting from the database, returning a default if not found.
    private func loadFloatSetting(_ key: String, default defaultValue: Float) -> Float {
        do {
            return try database.read { db in
                if let setting = try AppSettings
                    .filter(AppSettings.Columns.key == key)
                    .fetchOne(db),
                   let value = Float(setting.value) {
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
