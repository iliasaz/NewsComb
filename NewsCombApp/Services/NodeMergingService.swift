import Foundation
import GRDB
import OSLog

/// Result of a hypergraph simplification operation.
struct MergeResult: Sendable {
    let mergedPairs: Int
    let nodesRemoved: Int
    let embeddingsRecomputed: Int
}

/// Service for merging similar nodes in the hypergraph based on embedding similarity.
final class NodeMergingService: Sendable {

    private let database = Database.current
    private let logger = Logger(subsystem: "com.newscomb", category: "NodeMergingService")

    /// Default similarity threshold for merging (0.9 = 90% similar).
    static let defaultSimilarityThreshold: Float = 0.9

    // MARK: - Main Simplification

    /// Simplify the hypergraph by merging similar nodes.
    /// Based on the Python reference implementation in graph_tools.py.
    ///
    /// - Parameters:
    ///   - similarityThreshold: Minimum cosine similarity to consider nodes as candidates for merging (default 0.9)
    ///   - batchSize: Maximum number of nodes to process at once (for memory efficiency)
    /// - Returns: Result containing counts of merged pairs and removed nodes
    @concurrent
    func simplifyHypergraph(
        similarityThreshold: Float = defaultSimilarityThreshold,
        batchSize: Int = 500
    ) async throws -> MergeResult {
        let overallStart = ContinuousClock.now
        logger.info("Starting hypergraph simplification with threshold \(similarityThreshold)")

        // 1. Load all nodes with embeddings
        let loadStart = ContinuousClock.now
        let nodesWithEmbeddings = try loadNodesWithEmbeddings()
        logger.info("Loaded \(nodesWithEmbeddings.count) nodes with embeddings in \(ContinuousClock.now - loadStart)")

        guard nodesWithEmbeddings.count > 1 else {
            logger.info("Not enough nodes to merge")
            return MergeResult(mergedPairs: 0, nodesRemoved: 0, embeddingsRecomputed: 0)
        }

        // 2. Extract embeddings as Float arrays
        let nodeIds = nodesWithEmbeddings.map { $0.nodeId }
        let embeddings = nodesWithEmbeddings.map { $0.embedding }

        // 3. Find similar pairs above threshold
        logger.info("Searching for similar pairs across \(embeddings.count) embeddings…")
        let pairsStart = ContinuousClock.now
        let similarPairs = AccelerateVectorOps.findSimilarPairs(
            embeddings: embeddings,
            threshold: similarityThreshold
        )
        logger.info("Found \(similarPairs.count) pairs above threshold \(similarityThreshold) in \(ContinuousClock.now - pairsStart)")

        guard !similarPairs.isEmpty else {
            return MergeResult(mergedPairs: 0, nodesRemoved: 0, embeddingsRecomputed: 0)
        }

        // 4. Build merge plan: for each pair, keep the node with higher degree
        logger.info("Building merge plan from \(similarPairs.count) pairs…")
        let planStart = ContinuousClock.now
        let mergePlan = try buildMergePlan(
            nodeIds: nodeIds,
            similarPairs: similarPairs
        )
        logger.info("Merge plan: \(mergePlan.count) nodes to merge (built in \(ContinuousClock.now - planStart))")

        // 5. Execute merges
        logger.info("Executing \(mergePlan.count) merges…")
        let execStart = ContinuousClock.now
        let mergedCount = try executeMerges(mergePlan: mergePlan)
        logger.info("Executed \(mergedCount) merges in \(ContinuousClock.now - execStart)")

        logger.info("Simplification complete: merged \(mergedCount) nodes (total \(ContinuousClock.now - overallStart))")
        return MergeResult(
            mergedPairs: mergedCount,
            nodesRemoved: mergedCount,
            embeddingsRecomputed: 0  // Not recomputing for now
        )
    }

    // MARK: - Load Data

    private struct NodeWithEmbedding {
        let nodeId: Int64
        let label: String
        let embedding: [Float]
    }

    private func loadNodesWithEmbeddings() throws -> [NodeWithEmbedding] {
        try database.read { db in
            let sql = """
                SELECT hn.id, hn.label, ne.embedding
                FROM hypergraph_node hn
                JOIN node_embedding ne ON hn.id = ne.node_id
                ORDER BY hn.id
            """

            let rows = try Row.fetchAll(db, sql: sql)
            return rows.compactMap { row -> NodeWithEmbedding? in
                let nodeId: Int64 = row["id"]
                let label: String = row["label"]
                let embeddingData: Data = row["embedding"]

                // Convert Data to [Float]
                let floatCount = embeddingData.count / MemoryLayout<Float>.size
                guard floatCount > 0 else { return nil }

                let embedding = embeddingData.withUnsafeBytes { ptr in
                    Array(ptr.bindMemory(to: Float.self).prefix(floatCount))
                }

                return NodeWithEmbedding(nodeId: nodeId, label: label, embedding: embedding)
            }
        }
    }

    // MARK: - Build Merge Plan

    private struct MergeAction {
        let keepNodeId: Int64
        let keepLabel: String
        let removeNodeId: Int64
        let removeLabel: String
        let similarity: Double
    }

    private func buildMergePlan(
        nodeIds: [Int64],
        similarPairs: [AccelerateVectorOps.SimilarPair]
    ) throws -> [MergeAction] {
        // Get degrees (edge count) for all nodes
        let degreesStart = ContinuousClock.now
        let degrees = try getNodeDegrees(nodeIds: nodeIds)
        logger.info("Fetched node degrees for \(nodeIds.count) nodes in \(ContinuousClock.now - degreesStart)")

        var mergeActions: [MergeAction] = []
        var alreadyMerged = Set<Int64>()

        let logEvery = max(1, similarPairs.count / 10)
        var processed = 0

        for pair in similarPairs {
            let nodeIdI = nodeIds[pair.i]
            let nodeIdJ = nodeIds[pair.j]

            // Skip if either node is already being merged
            if alreadyMerged.contains(nodeIdI) || alreadyMerged.contains(nodeIdJ) {
                continue
            }

            let degreeI = degrees[nodeIdI] ?? 0
            let degreeJ = degrees[nodeIdJ] ?? 0

            // Keep the node with higher degree (more connected)
            let (keepId, removeId): (Int64, Int64)
            if degreeI >= degreeJ {
                keepId = nodeIdI
                removeId = nodeIdJ
            } else {
                keepId = nodeIdJ
                removeId = nodeIdI
            }

            // Get labels
            let keepLabel = try getNodeLabel(nodeId: keepId) ?? "unknown"
            let removeLabel = try getNodeLabel(nodeId: removeId) ?? "unknown"

            mergeActions.append(MergeAction(
                keepNodeId: keepId,
                keepLabel: keepLabel,
                removeNodeId: removeId,
                removeLabel: removeLabel,
                similarity: Double(pair.similarity)
            ))

            alreadyMerged.insert(removeId)
            processed += 1

            if processed % logEvery == 0 {
                logger.info("Merge plan progress: \(processed)/\(similarPairs.count) pairs evaluated, \(mergeActions.count) merges queued")
            }
        }

        return mergeActions
    }

    private func getNodeDegrees(nodeIds: [Int64]) throws -> [Int64: Int] {
        guard !nodeIds.isEmpty else { return [:] }

        // Aggregate degrees over the entire incidence table instead of binding
        // one placeholder per node. With ~143k nodes a `WHERE node_id IN (?,?…)`
        // exceeds SQLite's SQLITE_MAX_VARIABLE_NUMBER (999 on older builds,
        // 32,766 on newer ones). Orphan nodes never appear in `hypergraph_incidence`,
        // and the caller already treats missing entries as degree 0.
        return try database.read { db in
            let sql = """
                SELECT node_id, COUNT(*) as degree
                FROM hypergraph_incidence
                GROUP BY node_id
            """

            let rows = try Row.fetchAll(db, sql: sql)
            var degrees: [Int64: Int] = [:]
            degrees.reserveCapacity(rows.count)
            for row in rows {
                let nodeId: Int64 = row["node_id"]
                let degree: Int = row["degree"]
                degrees[nodeId] = degree
            }
            return degrees
        }
    }

    private func getNodeLabel(nodeId: Int64) throws -> String? {
        try database.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT label FROM hypergraph_node WHERE id = ?",
                arguments: [nodeId]
            )
        }
    }

    // MARK: - Execute Merges

    private func executeMerges(mergePlan: [MergeAction]) throws -> Int {
        var mergedCount = 0
        var failedCount = 0
        let logEvery = max(1, mergePlan.count / 20)
        let startTime = ContinuousClock.now

        for (index, action) in mergePlan.enumerated() {
            do {
                try executeSingleMerge(action: action)
                mergedCount += 1
                logger.debug("Merged '\(action.removeLabel, privacy: .public)' into '\(action.keepLabel, privacy: .public)' (similarity: \(String(format: "%.3f", action.similarity)))")
            } catch {
                failedCount += 1
                logger.warning("Failed to merge node \(action.removeNodeId): \(error.localizedDescription, privacy: .public)")
            }

            let completed = index + 1
            if completed == mergePlan.count || completed % logEvery == 0 {
                let elapsed = ContinuousClock.now - startTime
                logger.info("Merge progress: \(completed)/\(mergePlan.count) — \(mergedCount) merged, \(failedCount) failed, elapsed \(elapsed)")
            }
        }

        return mergedCount
    }

    private func executeSingleMerge(action: MergeAction) throws {
        try database.write { db in
            // 1. Update incidences: redirect edges from removed node to kept node
            try db.execute(sql: """
                UPDATE OR IGNORE hypergraph_incidence
                SET node_id = ?
                WHERE node_id = ?
            """, arguments: [action.keepNodeId, action.removeNodeId])

            // 2. Delete any duplicate incidences that might have been created
            try db.execute(sql: """
                DELETE FROM hypergraph_incidence
                WHERE node_id = ?
            """, arguments: [action.removeNodeId])

            // 3. Delete the embedding for the removed node
            try db.execute(sql: """
                DELETE FROM node_embedding WHERE node_id = ?
            """, arguments: [action.removeNodeId])

            // 4. Delete embedding metadata for the removed node
            try db.execute(sql: """
                DELETE FROM node_embedding_metadata WHERE node_id = ?
            """, arguments: [action.removeNodeId])

            // 5. Update any existing merge history records that reference the removed node as kept_node_id
            //    This handles the case where a previously-kept node is now being merged into another node
            try db.execute(sql: """
                UPDATE node_merge_history
                SET kept_node_id = ?
                WHERE kept_node_id = ?
            """, arguments: [action.keepNodeId, action.removeNodeId])

            // 6. Record the merge in history
            try NodeMergeHistory.recordMerge(
                db,
                keptNodeId: action.keepNodeId,
                removedNodeId: action.removeNodeId,
                removedNodeLabel: action.removeLabel,
                similarityScore: action.similarity
            )

            // 7. Delete the removed node
            try db.execute(sql: """
                DELETE FROM hypergraph_node WHERE id = ?
            """, arguments: [action.removeNodeId])
        }
    }

    // MARK: - Statistics

    /// Get the number of nodes that could potentially be merged.
    func getPotentialMergeCount(threshold: Float = defaultSimilarityThreshold) throws -> Int {
        let nodesWithEmbeddings = try loadNodesWithEmbeddings()
        guard nodesWithEmbeddings.count > 1 else { return 0 }

        let embeddings = nodesWithEmbeddings.map { $0.embedding }
        let similarPairs = AccelerateVectorOps.findSimilarPairs(
            embeddings: embeddings,
            threshold: threshold
        )

        return similarPairs.count
    }

    /// Get statistics about past merges.
    func getMergeStatistics() throws -> (totalMerges: Int, recentMerges: [NodeMergeHistory]) {
        try database.read { db in
            let total = try NodeMergeHistory.totalMergeCount(db)
            let recent = try NodeMergeHistory.recentMerges(db, limit: 10)
            return (totalMerges: total, recentMerges: recent)
        }
    }
}
