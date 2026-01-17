import Foundation
import GRDB
import HyperGraphReasoning
import os.log

/// Service for extracting and persisting hypergraph knowledge from articles.
final class HypergraphService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "HypergraphService")

    /// Progress callback during batch processing.
    typealias ProgressCallback = @MainActor @Sendable (Int, Int, String) -> Void

    // MARK: - Configuration

    /// Checks if the service is configured with an LLM provider.
    func isConfigured() -> Bool {
        do {
            return try database.read { db in
                // Check for Ollama endpoint with provider set to ollama
                if let providerSetting = try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.llmProvider)
                    .fetchOne(db),
                   providerSetting.value == "ollama" {
                    return true
                }

                // Check for OpenRouter key with provider set to openrouter
                if let providerSetting = try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.llmProvider)
                    .fetchOne(db),
                   providerSetting.value == "openrouter",
                   let keySetting = try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.openRouterKey)
                    .fetchOne(db),
                   !keySetting.value.isEmpty {
                    return true
                }

                return false
            }
        } catch {
            return false
        }
    }

    /// Gets the configured LLM provider type.
    func getLLMProvider() -> String? {
        do {
            return try database.read { db in
                if let setting = try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.llmProvider)
                    .fetchOne(db) {
                    return setting.value
                }
                return nil
            }
        } catch {
            return nil
        }
    }

    // MARK: - Article Processing

    /// Fetches articles that have full content but haven't been processed for hypergraph extraction.
    func getUnprocessedArticles() throws -> [FeedItem] {
        try database.read { db in
            let sql = """
                SELECT fi.*
                FROM feed_item fi
                LEFT JOIN article_hypergraph ah ON fi.id = ah.feed_item_id
                WHERE fi.full_content IS NOT NULL
                  AND fi.full_content != ''
                  AND (ah.id IS NULL OR ah.processing_status = 'failed')
                ORDER BY fi.pub_date DESC
            """
            return try FeedItem.fetchAll(db, sql: sql)
        }
    }

    /// Processes a single article to extract hypergraph.
    @MainActor
    func processArticle(feedItemId: Int64) async throws {
        logger.info("Starting to process article \(feedItemId)")

        // Get the feed item
        guard let feedItem = try database.read({ db in
            try FeedItem.filter(FeedItem.Columns.id == feedItemId).fetchOne(db)
        }) else {
            logger.error("Article \(feedItemId) not found in database")
            throw HypergraphServiceError.articleNotFound
        }

        logger.info("Found article: \(feedItem.title, privacy: .public)")

        guard let content = feedItem.fullContent, !content.isEmpty else {
            logger.warning("Article \(feedItemId) has no content")
            throw HypergraphServiceError.noContent
        }

        logger.info("Article content length: \(content.count) characters")

        // Mark as processing
        try updateProcessingStatus(feedItemId: feedItemId, status: .processing)
        logger.debug("Marked article \(feedItemId) as processing")

        do {
            // Create document processor
            logger.info("Creating document processor...")
            let processor = try await createDocumentProcessor()
            logger.info("Document processor created successfully")

            // Process the text
            logger.info("Processing text with HyperGraphReasoning...")
            let startTime = Date()
            let result = try await processor.processText(
                content,
                documentID: "\(feedItemId)",
                generateEmbeddings: true
            )
            let processingTime = Date().timeIntervalSince(startTime)
            logger.info("Text processing completed in \(String(format: "%.2f", processingTime))s")

            // Log hypergraph statistics
            let nodeCount = result.hypergraph.nodes.count
            let edgeCount = result.hypergraph.incidenceDict.count
            let embeddingCount = result.embeddings.embeddings.count
            let chunkCount = result.metadata.allChunkIDs.count
            logger.info("Extracted hypergraph: \(nodeCount) nodes, \(edgeCount) edges, \(embeddingCount) embeddings, \(chunkCount) chunks")

            // Log some sample nodes
            let sampleNodes = result.hypergraph.nodes.prefix(5)
            logger.debug("Sample nodes: \(sampleNodes.joined(separator: ", "), privacy: .public)")

            // Persist the hypergraph
            logger.info("Persisting hypergraph to database...")
            try persistHypergraph(result: result, feedItemId: feedItemId)
            logger.info("Hypergraph persisted successfully")

            // Mark as completed
            try updateProcessingStatus(
                feedItemId: feedItemId,
                status: .completed,
                chunkCount: chunkCount
            )
            logger.info("Article \(feedItemId) processing completed successfully")
        } catch {
            // Mark as failed
            logger.error("Failed to process article \(feedItemId): \(error.localizedDescription, privacy: .public)")
            try updateProcessingStatus(
                feedItemId: feedItemId,
                status: .failed,
                errorMessage: error.localizedDescription
            )
            throw error
        }
    }

    /// Maximum number of articles to process concurrently.
    private static let maxConcurrentProcessing = 4

    /// Processes all unprocessed articles with progress callback.
    /// Articles are processed in parallel with a configurable concurrency limit.
    @MainActor
    func processUnprocessedArticles(progressCallback: ProgressCallback?) async throws -> Int {
        let articles = try getUnprocessedArticles()
        logger.info("Found \(articles.count) unprocessed articles")

        guard !articles.isEmpty else {
            logger.info("No articles to process")
            return 0
        }

        let totalCount = articles.count
        var processedCount = 0
        var failedCount = 0

        logger.info("Starting parallel processing with max \(Self.maxConcurrentProcessing) concurrent tasks")

        // Process articles in batches with limited concurrency
        let batches = articles.chunked(into: Self.maxConcurrentProcessing)
        var completedSoFar = 0

        for batch in batches {
            // Process each batch in parallel
            let results = await withTaskGroup(of: (Int64, String, Bool).self, returning: [(Int64, String, Bool)].self) { group in
                for article in batch {
                    guard let articleId = article.id else { continue }
                    let title = article.title

                    group.addTask {
                        do {
                            try await self.processArticle(feedItemId: articleId)
                            return (articleId, title, true)
                        } catch {
                            return (articleId, title, false)
                        }
                    }
                }

                var batchResults: [(Int64, String, Bool)] = []
                for await result in group {
                    batchResults.append(result)
                }
                return batchResults
            }

            // Process batch results
            for (articleId, title, success) in results {
                completedSoFar += 1

                if success {
                    processedCount += 1
                    logger.info("Completed \(completedSoFar)/\(totalCount): \(title, privacy: .public) - SUCCESS")
                } else {
                    failedCount += 1
                    logger.warning("Completed \(completedSoFar)/\(totalCount): \(title, privacy: .public) - FAILED")
                }

                progressCallback?(completedSoFar, totalCount, title)
            }
        }

        logger.info("Batch processing complete: \(processedCount) succeeded, \(failedCount) failed out of \(totalCount) total")
        return processedCount
    }

    // MARK: - Document Processor Creation

    @MainActor
    private func createDocumentProcessor() async throws -> DocumentProcessor {
        let settings = try loadSettings()
        logger.info("LLM Provider: \(settings.provider, privacy: .public)")
        logger.info("Embedding Provider: \(settings.embeddingProvider, privacy: .public)")

        // Create the Ollama service for embeddings (always needed, may also be used for LLM)
        let embeddingOllama = createEmbeddingOllamaService(settings: settings)

        switch settings.provider {
        case "ollama":
            let endpoint = settings.ollamaEndpoint ?? "http://localhost:11434"
            let model = settings.ollamaModel ?? "llama3.2:3b"
            let embeddingModel = settings.embeddingOllamaModel ?? "nomic-embed-text:v1.5"
            logger.info("Configuring Ollama: endpoint=\(endpoint, privacy: .public), model=\(model, privacy: .public), embedding=\(embeddingModel, privacy: .public)")

            let host = URL(string: endpoint) ?? URL(string: "http://localhost:11434")!
            let ollama = OllamaService(
                host: host,
                chatModel: model,
                embeddingModel: embeddingModel
            )
            return DocumentProcessor(ollamaService: ollama)

        case "openrouter":
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                logger.error("OpenRouter API key is missing")
                throw HypergraphServiceError.missingAPIKey
            }
            let chatModel = settings.openRouterModel ?? "meta-llama/llama-4-maverick"
            logger.info("Configuring OpenRouter: model=\(chatModel, privacy: .public)")

            let openRouter = try OpenRouterService(
                apiKey: apiKey,
                model: chatModel
            )

            return DocumentProcessor(
                llmProvider: openRouter,
                ollamaService: embeddingOllama,
                chatModel: chatModel
            )

        default:
            logger.error("No LLM provider configured (provider value: '\(settings.provider, privacy: .public)')")
            throw HypergraphServiceError.noProviderConfigured
        }
    }

    /// Creates an OllamaService configured for embeddings based on settings.
    @MainActor
    private func createEmbeddingOllamaService(settings: LLMSettings) -> OllamaService {
        let embeddingEndpoint = settings.embeddingOllamaEndpoint ?? settings.ollamaEndpoint ?? "http://localhost:11434"
        let embeddingModel = settings.embeddingOllamaModel ?? "nomic-embed-text:v1.5"

        logger.info("Embedding Ollama: endpoint=\(embeddingEndpoint, privacy: .public), model=\(embeddingModel, privacy: .public)")

        if let host = URL(string: embeddingEndpoint) {
            return OllamaService(host: host, embeddingModel: embeddingModel)
        } else {
            return OllamaService(embeddingModel: embeddingModel)
        }
    }

    private func loadSettings() throws -> LLMSettings {
        try database.read { db in
            var settings = LLMSettings()

            // LLM settings
            if let provider = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.llmProvider)
                .fetchOne(db) {
                settings.provider = provider.value
            }

            if let endpoint = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.ollamaEndpoint)
                .fetchOne(db) {
                settings.ollamaEndpoint = endpoint.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.ollamaModel)
                .fetchOne(db) {
                settings.ollamaModel = model.value
            }

            if let key = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.openRouterKey)
                .fetchOne(db) {
                settings.openRouterKey = key.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.openRouterModel)
                .fetchOne(db) {
                settings.openRouterModel = model.value
            }

            // Embedding settings
            if let provider = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingProvider)
                .fetchOne(db) {
                settings.embeddingProvider = provider.value
            }

            if let endpoint = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingOllamaEndpoint)
                .fetchOne(db) {
                settings.embeddingOllamaEndpoint = endpoint.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingOllamaModel)
                .fetchOne(db) {
                settings.embeddingOllamaModel = model.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingOpenRouterModel)
                .fetchOne(db) {
                settings.embeddingOpenRouterModel = model.value
            }

            return settings
        }
    }

    // MARK: - Hypergraph Persistence

    private func persistHypergraph(result: ProcessingResult, feedItemId: Int64) throws {
        logger.debug("Beginning hypergraph persistence for article \(feedItemId)")
        var nodesInserted = 0
        var edgesInserted = 0
        var embeddingsStored = 0

        try database.write { db in
            // Process each edge in the hypergraph
            for (edgeId, nodeIds) in result.hypergraph.incidenceDict {
                // Find the metadata for this edge to get the relation
                let edgeMetadata = result.metadata.first { $0.edge == edgeId }
                let relation = edgeMetadata.map { self.extractRelation(from: $0) } ?? "unknown"

                // Upsert the edge
                let edgeRowId = try self.upsertEdge(db: db, edgeId: edgeId, relation: relation)
                edgesInserted += 1

                // Process nodes and create incidences
                for (position, nodeLabel) in nodeIds.enumerated() {
                    // Determine role based on metadata
                    let role: String
                    if let meta = edgeMetadata {
                        if meta.source.contains(nodeLabel) {
                            role = HypergraphIncidence.roleSource
                        } else if meta.target.contains(nodeLabel) {
                            role = HypergraphIncidence.roleTarget
                        } else {
                            role = "member"
                        }
                    } else {
                        role = "member"
                    }

                    // Upsert the node
                    let nodeRowId = try self.upsertNode(db: db, nodeId: nodeLabel, label: nodeLabel)
                    nodesInserted += 1

                    // Create incidence
                    try self.upsertIncidence(
                        db: db,
                        edgeId: edgeRowId,
                        nodeId: nodeRowId,
                        role: role,
                        position: position
                    )
                }

                // Create provenance link
                if let meta = edgeMetadata {
                    try self.upsertProvenance(
                        db: db,
                        edgeId: edgeRowId,
                        feedItemId: feedItemId,
                        chunkId: meta.chunkID
                    )
                }
            }

            self.logger.debug("Persisted \(edgesInserted) edges, \(nodesInserted) node references")

            // Store embeddings
            for (nodeLabel, embedding) in result.embeddings.embeddings {
                // Get the node's row ID
                if let node = try HypergraphNode
                    .filter(HypergraphNode.Columns.nodeId == nodeLabel)
                    .fetchOne(db),
                   let nodeRowId = node.id {
                    try self.storeEmbedding(db: db, nodeId: nodeRowId, embedding: embedding)
                    embeddingsStored += 1
                }
            }

            self.logger.debug("Stored \(embeddingsStored) embeddings")
        }

        logger.info("Persistence complete: \(edgesInserted) edges, \(nodesInserted) node refs, \(embeddingsStored) embeddings")
    }

    private func extractRelation(from metadata: ChunkMetadata) -> String {
        // Extract a relation string from metadata
        // The edge ID often contains the relation
        let parts = metadata.edge.components(separatedBy: "_")
        if parts.count > 1 {
            return parts.dropFirst().joined(separator: "_")
        }
        return metadata.edge
    }

    private func upsertNode(db: GRDB.Database, nodeId: String, label: String) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO hypergraph_node (node_id, label, first_seen_at)
                VALUES (?, ?, unixepoch())
                ON CONFLICT(node_id) DO UPDATE SET
                    label = excluded.label
            """,
            arguments: [nodeId, label]
        )

        // Get the row ID
        if let row = try Row.fetchOne(db, sql: "SELECT id FROM hypergraph_node WHERE node_id = ?", arguments: [nodeId]) {
            return row["id"]
        }
        throw HypergraphServiceError.databaseError("Failed to get node ID")
    }

    private func upsertEdge(db: GRDB.Database, edgeId: String, relation: String) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO hypergraph_edge (edge_id, relation, created_at)
                VALUES (?, ?, unixepoch())
                ON CONFLICT(edge_id) DO UPDATE SET
                    relation = excluded.relation
            """,
            arguments: [edgeId, relation]
        )

        // Get the row ID
        if let row = try Row.fetchOne(db, sql: "SELECT id FROM hypergraph_edge WHERE edge_id = ?", arguments: [edgeId]) {
            return row["id"]
        }
        throw HypergraphServiceError.databaseError("Failed to get edge ID")
    }

    private func upsertIncidence(db: GRDB.Database, edgeId: Int64, nodeId: Int64, role: String, position: Int) throws {
        try db.execute(
            sql: """
                INSERT INTO hypergraph_incidence (edge_id, node_id, role, position)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(edge_id, node_id, role) DO UPDATE SET
                    position = excluded.position
            """,
            arguments: [edgeId, nodeId, role, position]
        )
    }

    private func upsertProvenance(db: GRDB.Database, edgeId: Int64, feedItemId: Int64, chunkId: String) throws {
        // Extract chunk index from chunkId if possible
        let chunkIndex = Int(chunkId.components(separatedBy: "_").last ?? "0") ?? 0

        try db.execute(
            sql: """
                INSERT INTO article_edge_provenance (edge_id, feed_item_id, chunk_index)
                VALUES (?, ?, ?)
                ON CONFLICT(edge_id, feed_item_id, chunk_index) DO NOTHING
            """,
            arguments: [edgeId, feedItemId, chunkIndex]
        )
    }

    private func storeEmbedding(db: GRDB.Database, nodeId: Int64, embedding: [Float]) throws {
        // Convert Float array to blob for sqlite-vec
        let embeddingData = embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        // Virtual tables don't support UPSERT, so use DELETE + INSERT
        try db.execute(
            sql: "DELETE FROM node_embedding WHERE node_id = ?",
            arguments: [nodeId]
        )
        try db.execute(
            sql: "INSERT INTO node_embedding (node_id, embedding) VALUES (?, ?)",
            arguments: [nodeId, embeddingData]
        )
    }

    // MARK: - Processing Status

    private func updateProcessingStatus(
        feedItemId: Int64,
        status: HypergraphProcessingStatus,
        errorMessage: String? = nil,
        chunkCount: Int = 0
    ) throws {
        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO article_hypergraph (feed_item_id, processing_status, error_message, chunk_count, processed_at)
                    VALUES (?, ?, ?, ?, unixepoch())
                    ON CONFLICT(feed_item_id) DO UPDATE SET
                        processing_status = excluded.processing_status,
                        error_message = excluded.error_message,
                        chunk_count = excluded.chunk_count,
                        processed_at = unixepoch()
                """,
                arguments: [feedItemId, status.rawValue, errorMessage, chunkCount]
            )
        }
    }

    // MARK: - Similarity Search

    /// Finds articles similar to a given node.
    func findSimilarArticles(toNodeId nodeId: Int64, limit: Int = 20) throws -> [(feedItemId: Int64, distance: Double)] {
        try database.read { db in
            // Get the node's embedding
            guard let nodeEmbedding = try Row.fetchOne(
                db,
                sql: "SELECT embedding FROM node_embedding WHERE node_id = ?",
                arguments: [nodeId]
            ) else {
                return []
            }

            let embeddingData: Data = nodeEmbedding["embedding"]

            // Use sqlite-vec for similarity search
            let sql = """
                SELECT DISTINCT aep.feed_item_id, vec_distance_L2(ne.embedding, ?) as distance
                FROM hypergraph_node hn
                JOIN node_embedding ne ON hn.id = ne.node_id
                JOIN hypergraph_incidence hi ON hn.id = hi.node_id
                JOIN hypergraph_edge he ON hi.edge_id = he.id
                JOIN article_edge_provenance aep ON he.id = aep.edge_id
                WHERE ne.node_id != ?
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [embeddingData, nodeId, limit])
            return rows.map { row in
                (feedItemId: row["feed_item_id"] as Int64, distance: row["distance"] as Double)
            }
        }
    }

    /// Searches for similar concepts by text query.
    @MainActor
    func searchSimilarConcepts(query: String, limit: Int = 20) async throws -> [(nodeId: Int64, label: String, distance: Double)] {
        // Generate embedding for the query using configured embedding service
        let settings = try loadSettings()
        let ollama = createEmbeddingOllamaService(settings: settings)

        let queryEmbedding = try await ollama.embed(query)
        let embeddingData = queryEmbedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }

        // Search using sqlite-vec
        return try database.read { db in
            let sql = """
                SELECT hn.id, hn.label, vec_distance_L2(ne.embedding, ?) as distance
                FROM hypergraph_node hn
                JOIN node_embedding ne ON hn.id = ne.node_id
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [embeddingData, limit])
            return rows.map { row in
                (
                    nodeId: row["id"] as Int64,
                    label: row["label"] as String,
                    distance: row["distance"] as Double
                )
            }
        }
    }

    // MARK: - Statistics

    /// Gets hypergraph statistics.
    func getStatistics() throws -> HypergraphStatistics {
        try database.read { db in
            let nodeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node") ?? 0
            let edgeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_edge") ?? 0
            let processedArticles = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM article_hypergraph WHERE processing_status = 'completed'"
            ) ?? 0
            let embeddingCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM node_embedding") ?? 0

            return HypergraphStatistics(
                nodeCount: nodeCount,
                edgeCount: edgeCount,
                processedArticles: processedArticles,
                embeddingCount: embeddingCount
            )
        }
    }
}

// MARK: - Supporting Types

struct LLMSettings: Sendable {
    var provider: String = "ollama"
    var ollamaEndpoint: String?
    var ollamaModel: String?
    var openRouterKey: String?
    var openRouterModel: String?

    // Embedding configuration
    var embeddingProvider: String = "ollama"
    var embeddingOllamaEndpoint: String?
    var embeddingOllamaModel: String?
    var embeddingOpenRouterModel: String?
}

struct HypergraphStatistics: Sendable {
    let nodeCount: Int
    let edgeCount: Int
    let processedArticles: Int
    let embeddingCount: Int
}

enum HypergraphServiceError: Error, LocalizedError {
    case articleNotFound
    case noContent
    case missingAPIKey
    case noProviderConfigured
    case databaseError(String)

    var errorDescription: String? {
        switch self {
        case .articleNotFound:
            return "Article not found in database"
        case .noContent:
            return "Article has no content to process"
        case .missingAPIKey:
            return "API key is missing for the configured provider"
        case .noProviderConfigured:
            return "No LLM provider configured. Configure Ollama or OpenRouter in Settings."
        case .databaseError(let message):
            return "Database error: \(message)"
        }
    }
}

// MARK: - Array Chunking Extension

private extension Array {
    /// Splits the array into chunks of the specified size.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
