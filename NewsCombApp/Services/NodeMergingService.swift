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

    private let database = Database.shared
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
        logger.info("Starting hypergraph simplification with threshold \(similarityThreshold)")

        // 1. Load all nodes with embeddings
        let nodesWithEmbeddings = try loadNodesWithEmbeddings()
        logger.info("Loaded \(nodesWithEmbeddings.count) nodes with embeddings")

        guard nodesWithEmbeddings.count > 1 else {
            logger.info("Not enough nodes to merge")
            return MergeResult(mergedPairs: 0, nodesRemoved: 0, embeddingsRecomputed: 0)
        }

        // 2. Extract embeddings as Float arrays
        let nodeIds = nodesWithEmbeddings.map { $0.nodeId }
        let embeddings = nodesWithEmbeddings.map { $0.embedding }

        // 3. Find similar pairs above threshold
        let similarPairs = AccelerateVectorOps.findSimilarPairs(
            embeddings: embeddings,
            threshold: similarityThreshold
        )
        logger.info("Found \(similarPairs.count) pairs above threshold \(similarityThreshold)")

        guard !similarPairs.isEmpty else {
            return MergeResult(mergedPairs: 0, nodesRemoved: 0, embeddingsRecomputed: 0)
        }

        // 4. Build merge plan: for each pair, keep the node with higher degree
        let mergePlan = try buildMergePlan(
            nodeIds: nodeIds,
            similarPairs: similarPairs
        )
        logger.info("Merge plan: \(mergePlan.count) nodes to merge")

        // 5. Execute merges
        let mergedCount = try executeMerges(mergePlan: mergePlan)

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
        similarPairs: [(i: Int, j: Int, similarity: Float)]
    ) throws -> [MergeAction] {
        // Get degrees (edge count) for all nodes
        let degrees = try getNodeDegrees(nodeIds: nodeIds)

        var mergeActions: [MergeAction] = []
        var alreadyMerged = Set<Int64>()

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
        }

        return mergeActions
    }

    private func getNodeDegrees(nodeIds: [Int64]) throws -> [Int64: Int] {
        guard !nodeIds.isEmpty else { return [:] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ",")
            let sql = """
                SELECT node_id, COUNT(*) as degree
                FROM hypergraph_incidence
                WHERE node_id IN (\(placeholders))
                GROUP BY node_id
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(nodeIds))
            var degrees: [Int64: Int] = [:]
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

        for action in mergePlan {
            do {
                try executeSingleMerge(action: action)
                mergedCount += 1
                logger.debug("Merged '\(action.removeLabel, privacy: .public)' into '\(action.keepLabel, privacy: .public)' (similarity: \(String(format: "%.3f", action.similarity)))")
            } catch {
                logger.warning("Failed to merge node \(action.removeNodeId): \(error.localizedDescription, privacy: .public)")
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
