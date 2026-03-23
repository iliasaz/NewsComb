import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Classifies untyped hypergraph nodes by sending batches to a fast LLM.
///
/// Uses configurable batch size and concurrent task groups for throughput.
/// Reads node labels and edge context from the hypergraph, writes only to
/// hypergraph_node.node_type.
final class NodeClassificationService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "NodeClassification")

    typealias StatusCallback = @MainActor @Sendable (String) -> Void
    typealias ProgressCallback = @MainActor @Sendable (Double) -> Void

    /// Classifies all untyped nodes in the knowledge graph.
    func classifyUntypedNodes(
        statusCallback: StatusCallback? = nil,
        progressCallback: ProgressCallback? = nil
    ) async throws -> Int {
        // Load settings
        let config = try loadConfig()

        // Find untyped nodes
        let untypedNodes = try database.read { db in
            try HypergraphNode.filter(
                HypergraphNode.Columns.nodeType == nil
            ).fetchAll(db)
        }

        guard !untypedNodes.isEmpty else {
            await statusCallback?("All nodes already classified")
            return 0
        }

        await statusCallback?("Classifying \(untypedNodes.count) untyped nodes...")
        logger.info("Starting classification of \(untypedNodes.count) untyped nodes")

        // Create a single shared LLM client (OpenRouterService is an actor, safe to share)
        guard !config.openRouterKey.isEmpty else {
            throw ClassificationError.noApiKey
        }
        let llmClient = try OpenRouterService(apiKey: config.openRouterKey, model: config.model)

        // Split into batches
        let batches = untypedNodes.chunked(into: config.batchSize)
        var totalClassified = 0
        var processedBatches = 0

        // Process batches with concurrent task group limited by thread count.
        try await withThrowingTaskGroup(of: Int.self) { group in
            var running = 0
            var batchIterator = batches.makeIterator()

            // Seed initial tasks
            while running < config.threads, let batch = batchIterator.next() {
                let batchIndex = processedBatches + running
                group.addTask { @concurrent [self] in
                    try await self.classifyBatch(
                        batch,
                        batchIndex: batchIndex,
                        config: config,
                        llmClient: llmClient
                    )
                }
                running += 1
            }

            // As each completes, add next batch
            for try await classified in group {
                totalClassified += classified
                processedBatches += 1
                running -= 1

                let progress = Double(processedBatches) / Double(batches.count)
                await progressCallback?(progress)
                await statusCallback?("Classified \(totalClassified)/\(untypedNodes.count) nodes...")

                if let batch = batchIterator.next() {
                    let batchIndex = processedBatches + running
                    group.addTask { @concurrent [self] in
                        try await self.classifyBatch(
                            batch,
                            batchIndex: batchIndex,
                            config: config,
                            llmClient: llmClient
                        )
                    }
                    running += 1
                }
            }
        }

        await statusCallback?("Classification complete: \(totalClassified) nodes classified")
        logger.info("Classification complete: \(totalClassified)/\(untypedNodes.count) nodes classified")
        return totalClassified
    }

    /// Classifies a single batch of nodes via LLM.
    @concurrent
    private func classifyBatch(
        _ nodes: [HypergraphNode],
        batchIndex: Int,
        config: ClassificationConfig,
        llmClient: OpenRouterService
    ) async throws -> Int {
        // Build context for each node: label + edge relationships
        let nodeDescriptions = try nodes.map { node -> String in
            let edges = try database.read { db -> String in
                let sql = """
                    SELECT e.label AS edge_label,
                           src.label AS source_label,
                           tgt.label AS target_label
                    FROM hypergraph_incidence i
                    JOIN hypergraph_edge e ON e.id = i.edge_id
                    LEFT JOIN hypergraph_incidence si ON si.edge_id = e.id AND si.role = 'source'
                    LEFT JOIN hypergraph_node src ON src.id = si.node_id
                    LEFT JOIN hypergraph_incidence ti ON ti.edge_id = e.id AND ti.role = 'target'
                    LEFT JOIN hypergraph_node tgt ON tgt.id = ti.node_id
                    WHERE i.node_id = ?
                    LIMIT 5
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [node.id])
                return rows.map { row in
                    let src: String = row["source_label"] ?? "?"
                    let rel: String = row["edge_label"] ?? "?"
                    let tgt: String = row["target_label"] ?? "?"
                    return "\(src) -> \(rel) -> \(tgt)"
                }.joined(separator: "; ")
            }
            return "ID \(node.id!): \"\(node.label)\" [relationships: \(edges.isEmpty ? "none" : edges)]"
        }.joined(separator: "\n")

        let userPrompt = """
            Classify these entities:
            \(nodeDescriptions)
            """

        // Call LLM using the shared client
        let response = try await llmClient.chat(
            systemPrompt: config.prompt,
            userPrompt: userPrompt,
            model: config.model,
            temperature: 0.1
        )

        // Parse response: extract JSON array of {node_id, type}
        let classifications = parseClassifications(from: response)

        // Update database
        var classified = 0
        if !classifications.isEmpty {
            try database.write { db in
                for (nodeId, nodeType) in classifications {
                    try db.execute(
                        sql: "UPDATE hypergraph_node SET node_type = ? WHERE id = ? AND node_type IS NULL",
                        arguments: [nodeType, nodeId]
                    )
                    classified += 1
                }
            }
        }

        logger.info("Batch \(batchIndex): classified \(classified)/\(nodes.count) nodes")
        return classified
    }

    /// Parses LLM response for node classifications.
    /// Expects JSON array: [{"node_id": 1, "type": "person"}, ...]
    /// Handles markdown code blocks and partial JSON.
    func parseClassifications(from response: String) -> [(nodeId: Int64, type: String)] {
        // Extract JSON from potential markdown code blocks
        var jsonString = response
        if let start = response.range(of: "["),
           let end = response.range(of: "]", options: .backwards) {
            jsonString = String(response[start.lowerBound...end.lowerBound])
        }

        guard let data = jsonString.data(using: .utf8) else { return [] }

        struct Classification: Codable {
            let node_id: Int64
            let type: String
        }

        guard let items = try? JSONDecoder().decode([Classification].self, from: data) else {
            logger.warning("Failed to parse classification response")
            return []
        }

        // Validate types
        let validTypes: Set<String> = [
            "person", "organization", "company", "government", "institution",
            "product", "concept", "event", "location", "media", "other"
        ]

        return items.compactMap { item in
            let normalized = item.type.lowercased().trimmingCharacters(in: .whitespaces)
            guard validTypes.contains(normalized) else { return nil }
            return (nodeId: item.node_id, type: normalized)
        }
    }

    // MARK: - Config

    struct ClassificationConfig: Sendable {
        let model: String
        let prompt: String
        let batchSize: Int
        let threads: Int
        let openRouterKey: String
    }

    private func loadConfig() throws -> ClassificationConfig {
        try database.read { db in
            let model = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationModel).fetchOne(db)?.value
                ?? AppSettings.defaultSimClassificationModel
            let prompt = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationPrompt).fetchOne(db)?.value
                ?? AppSettings.defaultSimClassificationPrompt
            let batchSize = (try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationBatchSize).fetchOne(db)?.value)
                .flatMap { Int($0) } ?? AppSettings.defaultSimClassificationBatchSize
            let threads = (try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationThreads).fetchOne(db)?.value)
                .flatMap { Int($0) } ?? AppSettings.defaultSimClassificationThreads
            let apiKey = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterKey).fetchOne(db)?.value ?? ""

            return ClassificationConfig(
                model: model,
                prompt: prompt,
                batchSize: batchSize,
                threads: threads,
                openRouterKey: apiKey
            )
        }
    }

    // MARK: - LLM

    // LLM calls use the shared OpenRouterService instance passed to classifyBatch
}

enum ClassificationError: LocalizedError {
    case noApiKey
    case noUntypedNodes

    var errorDescription: String? {
        switch self {
        case .noApiKey: "OpenRouter API key not configured."
        case .noUntypedNodes: "All nodes are already classified."
        }
    }
}
