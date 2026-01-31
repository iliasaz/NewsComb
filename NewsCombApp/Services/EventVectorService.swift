import Accelerate
import Foundation
import GRDB
import OSLog

/// Builds event vectors for hyperedges by pooling node embeddings with IDF weighting
/// and concatenating a relation family one-hot encoding.
///
/// Event vector layout: `[normalize(sVec) | normalize(tVec) | normalize(diff) | relationOneHot]`
/// where `sVec` / `tVec` are IDF-weighted means of source/target node embeddings.
final class EventVectorService: Sendable {
    /// Maximum IDF value to clamp hub nodes.
    static let idfMax: Double = 6.0

    /// Dimension of node embeddings from the embedding model (read from settings).
    let embeddingDim: Int
    /// Total dimension of the final event vector: `3 * embeddingDim + RelationFamily.count`.
    let eventVecDim: Int

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "EventVectorService")

    init() {
        let dim = Self.loadEmbeddingDimension()
        self.embeddingDim = dim
        self.eventVecDim = 3 * dim + RelationFamily.count
    }

    /// Reads the embedding dimension from app settings.
    private static func loadEmbeddingDimension() -> Int {
        do {
            return try Database.shared.read { db in
                if let setting = try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.embeddingDimension)
                    .fetchOne(db),
                   let value = Int(setting.value) {
                    return min(value, AppSettings.maxEmbeddingDimension)
                }
                return AppSettings.defaultEmbeddingDimension
            }
        } catch {
            return AppSettings.defaultEmbeddingDimension
        }
    }

    /// Callback for progress updates during vector computation.
    typealias ProgressCallback = @MainActor @Sendable (String) -> Void

    // MARK: - DF / IDF

    /// Computes document frequency and IDF for every node.
    ///
    /// `df(node)` = number of distinct edges where the node participates.
    /// `idf(node) = min(log((N+1)/(df+1)) + 1, idfMax)`
    func computeIDFWeights(progressCallback: ProgressCallback? = nil) throws {
        try database.write { db in
            // Total number of edges (events)
            let totalEvents = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM hypergraph_edge"
            ) ?? 0

            guard totalEvents > 0 else {
                logger.info("No events to compute IDF for")
                return
            }

            // Compute DF per node via incidence table
            try db.execute(sql: """
                UPDATE hypergraph_node
                SET df = (
                    SELECT COUNT(DISTINCT hi.edge_id)
                    FROM hypergraph_incidence hi
                    WHERE hi.node_id = hypergraph_node.id
                )
            """)

            // Compute IDF in Swift (SQLite lacks LOG/ln functions)
            let idfMax = Self.idfMax
            let n = Double(totalEvents)
            let nodes = try Row.fetchAll(db, sql: "SELECT id, COALESCE(df, 0) as df FROM hypergraph_node")

            for row in nodes {
                let nodeId: Int64 = row["id"]
                let df: Int = row["df"]
                let idf = min(Foundation.log((n + 1.0) / (Double(df) + 1.0)) + 1.0, idfMax)
                try db.execute(
                    sql: "UPDATE hypergraph_node SET idf = ? WHERE id = ?",
                    arguments: [idf, nodeId]
                )
            }

            logger.info("Computed IDF weights for \(nodes.count) nodes across \(totalEvents) events")
        }
    }

    // MARK: - Event Vectors

    /// Represents a loaded event with its participants and verb for vector construction.
    struct EventData {
        let edgeId: Int64
        let verb: String
        let sourceNodeIds: [Int64]
        let targetNodeIds: [Int64]
    }

    /// Builds event vectors for all edges and persists them to the `event_vectors` table.
    func buildEventVectors(progressCallback: ProgressCallback? = nil) async throws {
        // Load all node embeddings and IDF weights into memory
        let (nodeEmbeddings, nodeIDFs) = try loadNodeEmbeddingsAndIDFs()

        guard !nodeEmbeddings.isEmpty else {
            logger.warning("No node embeddings found — cannot build event vectors")
            return
        }

        // Load all events (edges with their source/target nodes)
        let events = try loadAllEvents()
        logger.info("Building vectors for \(events.count) events using \(nodeEmbeddings.count) node embeddings")

        // Clear existing event vectors
        try database.write { db in
            try db.execute(sql: "DELETE FROM event_vectors")
        }

        // Build vectors in batches
        let batchSize = 500
        var built = 0

        for batchStart in stride(from: 0, to: events.count, by: batchSize) {
            try Task.checkCancellation()

            let batchEnd = min(batchStart + batchSize, events.count)
            let batch = events[batchStart..<batchEnd]

            var insertSQL = ""
            var insertArgs: [any DatabaseValueConvertible] = []

            for event in batch {
                guard let vec = buildSingleEventVector(
                    event: event,
                    nodeEmbeddings: nodeEmbeddings,
                    nodeIDFs: nodeIDFs
                ) else { continue }

                // Convert [Float] to Data for sqlite-vec
                let vecData = vec.withUnsafeBufferPointer { buffer in
                    Data(buffer: buffer)
                }

                insertSQL += "INSERT INTO event_vectors (event_id, vec) VALUES (?, ?);\n"
                insertArgs.append(event.edgeId)
                insertArgs.append(vecData)
                built += 1
            }

            if !insertSQL.isEmpty {
                try database.write { db in
                    // sqlite-vec requires individual inserts
                    var argIndex = 0
                    for _ in batch {
                        guard argIndex + 1 < insertArgs.count else { break }
                        try db.execute(
                            sql: "INSERT INTO event_vectors (event_id, vec) VALUES (?, ?)",
                            arguments: [insertArgs[argIndex], insertArgs[argIndex + 1]]
                        )
                        argIndex += 2
                    }
                }
            }

            let progress = "Built \(min(batchEnd, events.count))/\(events.count) event vectors"
            await progressCallback?(progress)
        }

        logger.info("Built \(built) event vectors out of \(events.count) events")
    }

    // MARK: - Private

    /// Loads all node embeddings and IDF weights from the database.
    private func loadNodeEmbeddingsAndIDFs() throws -> (
        embeddings: [Int64: [Float]],
        idfs: [Int64: Double]
    ) {
        try database.read { db in
            var embeddings: [Int64: [Float]] = [:]
            var idfs: [Int64: Double] = [:]

            // Load embeddings
            let embRows = try Row.fetchAll(db, sql: """
                SELECT ne.node_id, ne.embedding
                FROM node_embedding ne
            """)

            for row in embRows {
                let nodeId: Int64 = row["node_id"]
                let data: Data = row["embedding"]
                let floats = data.withUnsafeBytes { buffer in
                    Array(buffer.bindMemory(to: Float.self))
                }
                if floats.count == self.embeddingDim {
                    embeddings[nodeId] = floats
                }
            }

            // Load IDF weights
            let idfRows = try Row.fetchAll(db, sql: """
                SELECT id, COALESCE(idf, 1.0) as idf FROM hypergraph_node
            """)

            for row in idfRows {
                let nodeId: Int64 = row["id"]
                let idf: Double = row["idf"]
                idfs[nodeId] = idf
            }

            return (embeddings, idfs)
        }
    }

    /// Loads all events (edges + their source/target participants) from the database.
    private func loadAllEvents() throws -> [EventData] {
        try database.read { db in
            // Load all edges
            let edges = try Row.fetchAll(db, sql: """
                SELECT id, label FROM hypergraph_edge ORDER BY id
            """)

            // Load all incidences grouped by edge
            let incidences = try Row.fetchAll(db, sql: """
                SELECT edge_id, node_id, role
                FROM hypergraph_incidence
                ORDER BY edge_id, role, position
            """)

            // Group incidences by edge_id
            var edgeSources: [Int64: [Int64]] = [:]
            var edgeTargets: [Int64: [Int64]] = [:]

            for row in incidences {
                let edgeId: Int64 = row["edge_id"]
                let nodeId: Int64 = row["node_id"]
                let role: String = row["role"]

                if role == "source" {
                    edgeSources[edgeId, default: []].append(nodeId)
                } else {
                    edgeTargets[edgeId, default: []].append(nodeId)
                }
            }

            return edges.compactMap { row -> EventData? in
                let edgeId: Int64 = row["id"]
                let verb: String = row["label"]
                let sources = edgeSources[edgeId] ?? []
                let targets = edgeTargets[edgeId] ?? []

                // Skip edges with no participants
                guard !sources.isEmpty || !targets.isEmpty else { return nil }

                return EventData(
                    edgeId: edgeId,
                    verb: verb,
                    sourceNodeIds: sources,
                    targetNodeIds: targets
                )
            }
        }
    }

    /// Builds a single event vector from an event's participants and verb.
    ///
    /// Layout: `[normalize(sVec) | normalize(tVec) | normalize(diff) | relationOneHot]`
    private func buildSingleEventVector(
        event: EventData,
        nodeEmbeddings: [Int64: [Float]],
        nodeIDFs: [Int64: Double]
    ) -> [Float]? {
        let dim = self.embeddingDim

        // Pool source embeddings with IDF weighting
        let sVec = weightedMeanEmbedding(
            nodeIds: event.sourceNodeIds,
            embeddings: nodeEmbeddings,
            idfs: nodeIDFs,
            dim: dim
        )

        // Pool target embeddings with IDF weighting
        let tVec = weightedMeanEmbedding(
            nodeIds: event.targetNodeIds,
            embeddings: nodeEmbeddings,
            idfs: nodeIDFs,
            dim: dim
        )

        // Need at least one of source or target
        guard sVec != nil || tVec != nil else { return nil }

        let s = sVec ?? [Float](repeating: 0, count: dim)
        let t = tVec ?? [Float](repeating: 0, count: dim)

        // Directional difference
        var diff = [Float](repeating: 0, count: dim)
        vDSP_vsub(s, 1, t, 1, &diff, 1, vDSP_Length(dim))

        // Normalize each component
        let sNorm = AccelerateVectorOps.normalize(s)
        let tNorm = AccelerateVectorOps.normalize(t)
        let diffNorm = AccelerateVectorOps.normalize(diff)

        // Relation family one-hot
        let family = RelationFamily.classify(event.verb)
        let oneHot = family.oneHot

        // Concatenate: sNorm | tNorm | diffNorm | oneHot
        var result = [Float]()
        result.reserveCapacity(self.eventVecDim)
        result.append(contentsOf: sNorm)
        result.append(contentsOf: tNorm)
        result.append(contentsOf: diffNorm)
        result.append(contentsOf: oneHot)

        return result
    }

    /// Computes the IDF-weighted mean of embeddings for a set of node IDs.
    private func weightedMeanEmbedding(
        nodeIds: [Int64],
        embeddings: [Int64: [Float]],
        idfs: [Int64: Double],
        dim: Int
    ) -> [Float]? {
        guard !nodeIds.isEmpty else { return nil }

        var weightedSum = [Float](repeating: 0, count: dim)
        var totalWeight: Float = 0

        for nodeId in nodeIds {
            guard let emb = embeddings[nodeId] else { continue }
            let weight = Float(idfs[nodeId] ?? 1.0)

            // weightedSum += weight * emb
            var scaledEmb = [Float](repeating: 0, count: dim)
            var w = weight
            vDSP_vsmul(emb, 1, &w, &scaledEmb, 1, vDSP_Length(dim))
            vDSP_vadd(weightedSum, 1, scaledEmb, 1, &weightedSum, 1, vDSP_Length(dim))

            totalWeight += weight
        }

        guard totalWeight > 0 else { return nil }

        // Divide by total weight
        var invWeight = 1.0 / totalWeight
        vDSP_vsmul(weightedSum, 1, &invWeight, &weightedSum, 1, vDSP_Length(dim))

        return weightedSum
    }
}
