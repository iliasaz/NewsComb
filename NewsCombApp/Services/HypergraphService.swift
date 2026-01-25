import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Service for extracting and persisting hypergraph knowledge from articles.
final class HypergraphService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "HypergraphService")

    // Cancellation support (accessed only from @MainActor methods)
    @MainActor private var isCancelled = false

    /// Request cancellation of the current batch processing.
    @MainActor
    func cancelProcessing() {
        isCancelled = true
        logger.info("Cancellation requested")
    }

    /// Reset the cancellation flag for a new processing run.
    @MainActor
    private func resetCancellation() {
        isCancelled = false
    }

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
            try persistHypergraph(result: result, feedItemId: feedItemId, content: content)
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

    /// Processes all unprocessed articles with progress callback.
    /// Articles are processed in parallel with a configurable concurrency limit.
    /// Processing can be cancelled by calling `cancelProcessing()`.
    @MainActor
    func processUnprocessedArticles(progressCallback: ProgressCallback?) async throws -> Int {
        resetCancellation()

        let articles = try getUnprocessedArticles()
        logger.info("Found \(articles.count) unprocessed articles")

        guard !articles.isEmpty else {
            logger.info("No articles to process")
            return 0
        }

        // Load max concurrent setting
        let settings = try loadSettings()
        let maxConcurrent = settings.maxConcurrentProcessing

        let totalCount = articles.count
        var processedCount = 0
        var failedCount = 0

        logger.info("Starting parallel processing with max \(maxConcurrent) concurrent tasks")

        // Process articles in batches with limited concurrency
        let batches = articles.chunked(into: maxConcurrent)
        var completedSoFar = 0

        for batch in batches {
            // Check for cancellation before starting each batch
            if isCancelled {
                logger.info("Processing cancelled after \(completedSoFar) articles")
                progressCallback?(completedSoFar, totalCount, "Cancelled")
                throw HypergraphServiceError.cancelled
            }

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

            // Check for cancellation after each batch
            if isCancelled {
                logger.info("Processing cancelled after \(completedSoFar) articles")
                progressCallback?(completedSoFar, totalCount, "Cancelled")
                throw HypergraphServiceError.cancelled
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

            if let extractionPrompt = settings.extractionSystemPrompt {
                logger.info("Using custom extraction prompt (\(extractionPrompt.count) chars)")
            }

            let host = URL(string: endpoint) ?? URL(string: "http://localhost:11434")!
            let ollama = OllamaService(
                host: host,
                chatModel: model,
                embeddingModel: embeddingModel
            )
            return DocumentProcessor(
                ollamaService: ollama,
                extractionSystemPrompt: settings.extractionSystemPrompt,
                distillationSystemPrompt: settings.distillationSystemPrompt
            )

        case "openrouter":
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                logger.error("OpenRouter API key is missing")
                throw HypergraphServiceError.missingAPIKey
            }
            let chatModel = settings.openRouterModel ?? "meta-llama/llama-4-maverick"
            logger.info("Configuring OpenRouter: model=\(chatModel, privacy: .public)")

            if let extractionPrompt = settings.extractionSystemPrompt {
                logger.info("Using custom extraction prompt (\(extractionPrompt.count) chars)")
            }

            let openRouter = try OpenRouterService(
                apiKey: apiKey,
                model: chatModel
            )

            return DocumentProcessor(
                llmProvider: openRouter,
                ollamaService: embeddingOllama,
                chatModel: chatModel,
                extractionSystemPrompt: settings.extractionSystemPrompt,
                distillationSystemPrompt: settings.distillationSystemPrompt
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

            // Processing configuration
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.maxConcurrentProcessing)
                .fetchOne(db),
               let value = Int(setting.value) {
                settings.maxConcurrentProcessing = value
            }

            // Custom prompts
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.extractionSystemPrompt)
                .fetchOne(db),
               !setting.value.isEmpty {
                settings.extractionSystemPrompt = setting.value
            }

            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.distillationSystemPrompt)
                .fetchOne(db),
               !setting.value.isEmpty {
                settings.distillationSystemPrompt = setting.value
            }

            return settings
        }
    }

    /// Gets the configured embedding model name for tracking.
    private func getEmbeddingModelName() throws -> String? {
        try database.read { db in
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingOllamaModel)
                .fetchOne(db) {
                return setting.value
            }
            return nil
        }
    }

    // MARK: - Hypergraph Persistence

    private func persistHypergraph(result: ProcessingResult, feedItemId: Int64, content: String) throws {
        logger.debug("Beginning hypergraph persistence for article \(feedItemId)")
        var nodesInserted = 0
        var edgesInserted = 0
        var embeddingsStored = 0
        var chunksStored = 0

        // Get embedding model name BEFORE the write transaction to avoid reentrancy
        let embeddingModel = try getEmbeddingModelName()

        // Chunk the content for provenance tracking
        let chunks = TextChunker.chunkText(content)

        try database.write { db in
            // Store article chunks and build a mapping from chunk index to chunk row ID
            var chunkIdMap: [Int: Int64] = [:]
            for (index, chunkContent) in chunks.enumerated() {
                let chunkRowId = try self.upsertArticleChunk(
                    db: db,
                    feedItemId: feedItemId,
                    chunkIndex: index,
                    content: chunkContent
                )
                chunkIdMap[index] = chunkRowId
                chunksStored += 1
            }

            // Process each edge in the hypergraph
            for (edgeId, nodeIds) in result.hypergraph.incidenceDict {
                // Find the metadata for this edge to get the relation
                let edgeMetadata = result.metadata.first { $0.edge == edgeId }
                let relation = edgeMetadata.map { self.extractRelation(from: $0) } ?? "unknown"

                // Extract chunk index from metadata
                let chunkIndex: Int?
                if let meta = edgeMetadata {
                    chunkIndex = Int(meta.chunkID.components(separatedBy: "_").last ?? "")
                } else {
                    chunkIndex = nil
                }

                // Get the chunk row ID if available
                let sourceChunkId = chunkIndex.flatMap { chunkIdMap[$0] }

                // Upsert the edge with source chunk reference
                let edgeRowId = try self.upsertEdge(
                    db: db,
                    edgeId: edgeId,
                    relation: relation,
                    sourceChunkId: sourceChunkId
                )
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

                // Create provenance link with chunk text
                if let meta = edgeMetadata {
                    let chunkText = chunkIndex.flatMap { idx in
                        idx < chunks.count ? chunks[idx] : nil
                    }
                    try self.upsertProvenance(
                        db: db,
                        edgeId: edgeRowId,
                        feedItemId: feedItemId,
                        chunkId: meta.chunkID,
                        chunkText: chunkText
                    )
                }
            }

            self.logger.debug("Persisted \(edgesInserted) edges, \(nodesInserted) node references, \(chunksStored) chunks")

            // Store embeddings only for nodes that don't already have them (incremental)
            var skippedEmbeddings = 0
            for (nodeLabel, embedding) in result.embeddings.embeddings {
                // Get the node's row ID
                if let node = try HypergraphNode
                    .filter(HypergraphNode.Columns.nodeId == nodeLabel)
                    .fetchOne(db),
                   let nodeRowId = node.id {

                    // Check if this node already has an embedding
                    if try NodeEmbeddingMetadata.hasEmbedding(db, nodeId: nodeRowId) {
                        skippedEmbeddings += 1
                        continue
                    }

                    // Store the embedding and track in metadata
                    try self.storeEmbedding(db: db, nodeId: nodeRowId, embedding: embedding)
                    try NodeEmbeddingMetadata.markEmbeddingComputed(db, nodeId: nodeRowId, modelName: embeddingModel)
                    embeddingsStored += 1
                }
            }

            if skippedEmbeddings > 0 {
                self.logger.debug("Skipped \(skippedEmbeddings) embeddings (already exist)")
            }
            self.logger.debug("Stored \(embeddingsStored) new embeddings")
        }

        logger.info("Persistence complete: \(edgesInserted) edges, \(nodesInserted) node refs, \(embeddingsStored) embeddings, \(chunksStored) chunks")
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

    private func upsertEdge(db: GRDB.Database, edgeId: String, relation: String, sourceChunkId: Int64? = nil) throws -> Int64 {
        if let chunkId = sourceChunkId {
            try db.execute(
                sql: """
                    INSERT INTO hypergraph_edge (edge_id, relation, source_chunk_id, created_at)
                    VALUES (?, ?, ?, unixepoch())
                    ON CONFLICT(edge_id) DO UPDATE SET
                        relation = excluded.relation,
                        source_chunk_id = COALESCE(excluded.source_chunk_id, source_chunk_id)
                """,
                arguments: [edgeId, relation, chunkId]
            )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO hypergraph_edge (edge_id, relation, created_at)
                    VALUES (?, ?, unixepoch())
                    ON CONFLICT(edge_id) DO UPDATE SET
                        relation = excluded.relation
                """,
                arguments: [edgeId, relation]
            )
        }

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

    private func upsertProvenance(db: GRDB.Database, edgeId: Int64, feedItemId: Int64, chunkId: String, chunkText: String? = nil) throws {
        // Extract chunk index from chunkId if possible
        let chunkIndex = Int(chunkId.components(separatedBy: "_").last ?? "0") ?? 0

        try db.execute(
            sql: """
                INSERT INTO article_edge_provenance (edge_id, feed_item_id, chunk_index, chunk_text)
                VALUES (?, ?, ?, ?)
                ON CONFLICT(edge_id, feed_item_id, chunk_index) DO UPDATE SET
                    chunk_text = COALESCE(excluded.chunk_text, chunk_text)
            """,
            arguments: [edgeId, feedItemId, chunkIndex, chunkText]
        )
    }

    private func upsertArticleChunk(db: GRDB.Database, feedItemId: Int64, chunkIndex: Int, content: String) throws -> Int64 {
        try db.execute(
            sql: """
                INSERT INTO article_chunk (feed_item_id, chunk_index, content, created_at)
                VALUES (?, ?, ?, unixepoch())
                ON CONFLICT(feed_item_id, chunk_index) DO UPDATE SET
                    content = excluded.content
            """,
            arguments: [feedItemId, chunkIndex, content]
        )

        // Get the row ID
        if let row = try Row.fetchOne(
            db,
            sql: "SELECT id FROM article_chunk WHERE feed_item_id = ? AND chunk_index = ?",
            arguments: [feedItemId, chunkIndex]
        ) {
            return row["id"]
        }
        throw HypergraphServiceError.databaseError("Failed to get article chunk ID")
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

    // MARK: - Enhanced Node Merging

    /// Finds nodes similar to a given node using embedding similarity.
    /// - Parameters:
    ///   - nodeId: The ID of the node to find similar nodes for
    ///   - threshold: Similarity threshold (0-1, default 0.85)
    ///   - limit: Maximum number of similar nodes to return
    /// - Returns: Array of similar nodes with their similarity scores
    func findSimilarNodes(to nodeId: Int64, threshold: Float = 0.85, limit: Int = 20) throws -> [(node: HypergraphNode, similarity: Double)] {
        try database.read { db in
            // Get the source node's embedding
            guard let sourceEmbedding = try Row.fetchOne(
                db,
                sql: "SELECT embedding FROM node_embedding WHERE node_id = ?",
                arguments: [nodeId]
            ) else {
                logger.debug("No embedding found for node \(nodeId)")
                return []
            }

            let embeddingData: Data = sourceEmbedding["embedding"]

            // Convert threshold to L2 distance threshold
            // For normalized vectors: L2_distance = sqrt(2 * (1 - cosine_similarity))
            // So: cosine_similarity = 1 - (L2_distance^2 / 2)
            // Inverse: L2_distance = sqrt(2 * (1 - threshold))
            let distanceThreshold = sqrt(2 * (1 - Double(threshold)))

            let sql = """
                SELECT hn.*, vec_distance_L2(ne.embedding, ?) as distance
                FROM hypergraph_node hn
                JOIN node_embedding ne ON hn.id = ne.node_id
                WHERE hn.id != ?
                  AND vec_distance_L2(ne.embedding, ?) < ?
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [embeddingData, nodeId, embeddingData, distanceThreshold, limit]
            )

            return rows.compactMap { row -> (node: HypergraphNode, similarity: Double)? in
                guard let node = try? HypergraphNode(row: row) else { return nil }
                let distance: Double = row["distance"]
                // Convert L2 distance to cosine similarity
                let similarity = 1 - (distance * distance / 2)
                return (node, similarity)
            }
        }
    }

    /// Merges a source node into a target node, transferring all relationships.
    /// - Parameters:
    ///   - sourceId: The ID of the node to merge (will be deleted)
    ///   - targetId: The ID of the node to merge into (will be kept)
    ///   - similarityScore: The similarity score between the nodes (for history tracking)
    func mergeNodes(_ sourceId: Int64, into targetId: Int64, similarityScore: Double = 0) throws {
        try database.write { db in
            // Get source node info for history
            guard let sourceNode = try HypergraphNode.filter(HypergraphNode.Columns.id == sourceId).fetchOne(db) else {
                throw HypergraphServiceError.databaseError("Source node not found")
            }

            logger.info("Merging node '\(sourceNode.label, privacy: .public)' (id: \(sourceId)) into node \(targetId)")

            // Update all incidences to point to target node
            try db.execute(
                sql: """
                    UPDATE hypergraph_incidence
                    SET node_id = ?
                    WHERE node_id = ?
                """,
                arguments: [targetId, sourceId]
            )

            // Handle duplicate incidences that may arise from the merge
            // Delete duplicates keeping only the first one
            try db.execute(
                sql: """
                    DELETE FROM hypergraph_incidence
                    WHERE id NOT IN (
                        SELECT MIN(id)
                        FROM hypergraph_incidence
                        GROUP BY edge_id, node_id, role
                    )
                """
            )

            // Record merge history
            try db.execute(
                sql: """
                    INSERT INTO node_merge_history (kept_node_id, removed_node_id, removed_node_label, similarity_score)
                    VALUES (?, ?, ?, ?)
                """,
                arguments: [targetId, sourceId, sourceNode.label, similarityScore]
            )

            // Delete source node's embedding
            try db.execute(
                sql: "DELETE FROM node_embedding WHERE node_id = ?",
                arguments: [sourceId]
            )
            try db.execute(
                sql: "DELETE FROM node_embedding_metadata WHERE node_id = ?",
                arguments: [sourceId]
            )

            // Delete the source node
            try db.execute(
                sql: "DELETE FROM hypergraph_node WHERE id = ?",
                arguments: [sourceId]
            )

            // Clean up orphaned edges (edges with no remaining incidences)
            try db.execute(
                sql: """
                    DELETE FROM hypergraph_edge
                    WHERE id NOT IN (SELECT DISTINCT edge_id FROM hypergraph_incidence)
                """
            )

            logger.info("Node merge completed successfully")
        }
    }

    /// Gets merge suggestions based on embedding similarity.
    /// - Parameters:
    ///   - threshold: Similarity threshold for suggestions (0-1, default 0.85)
    ///   - limit: Maximum number of suggestions to return
    /// - Returns: Array of merge suggestions with source, target, and similarity
    func getMergeSuggestions(threshold: Float = 0.85, limit: Int = 50) throws -> [MergeSuggestion] {
        try database.read { db in
            // Convert threshold to L2 distance threshold
            let distanceThreshold = sqrt(2 * (1 - Double(threshold)))

            // Find similar node pairs using a self-join with sqlite-vec
            // We need to compare each node's embedding against all others
            let sql = """
                SELECT
                    hn1.id as node1_id, hn1.label as node1_label, hn1.node_type as node1_type,
                    hn2.id as node2_id, hn2.label as node2_label, hn2.node_type as node2_type,
                    vec_distance_L2(ne1.embedding, ne2.embedding) as distance
                FROM hypergraph_node hn1
                JOIN node_embedding ne1 ON hn1.id = ne1.node_id
                JOIN hypergraph_node hn2 ON hn1.id < hn2.id
                JOIN node_embedding ne2 ON hn2.id = ne2.node_id
                WHERE vec_distance_L2(ne1.embedding, ne2.embedding) < ?
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [distanceThreshold, limit])

            return rows.map { row in
                let distance: Double = row["distance"]
                let similarity = 1 - (distance * distance / 2)

                return MergeSuggestion(
                    node1Id: row["node1_id"],
                    node1Label: row["node1_label"],
                    node1Type: row["node1_type"],
                    node2Id: row["node2_id"],
                    node2Label: row["node2_label"],
                    node2Type: row["node2_type"],
                    similarity: similarity
                )
            }
        }
    }
}

/// A suggestion for merging two similar nodes.
struct MergeSuggestion: Identifiable, Sendable {
    var id: String { "\(node1Id)-\(node2Id)" }

    let node1Id: Int64
    let node1Label: String
    let node1Type: String?
    let node2Id: Int64
    let node2Label: String
    let node2Type: String?
    let similarity: Double
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

    // Analysis LLM configuration (for answers and deep analysis)
    // Falls back to main LLM settings if not configured
    var analysisProvider: String?
    var analysisOllamaEndpoint: String?
    var analysisOllamaModel: String?
    var analysisOpenRouterModel: String?

    // Processing configuration
    var maxConcurrentProcessing: Int = AppSettings.defaultMaxConcurrentProcessing

    // Custom prompts (nil means use defaults)
    var extractionSystemPrompt: String?
    var distillationSystemPrompt: String?

    // MARK: - Analysis LLM Helpers

    /// Returns the effective provider for analysis, falling back to main provider.
    var effectiveAnalysisProvider: String {
        if let provider = analysisProvider, !provider.isEmpty {
            return provider
        }
        return provider
    }

    /// Returns the effective Ollama endpoint for analysis.
    var effectiveAnalysisOllamaEndpoint: String? {
        analysisOllamaEndpoint ?? ollamaEndpoint
    }

    /// Returns the effective Ollama model for analysis.
    var effectiveAnalysisOllamaModel: String? {
        analysisOllamaModel ?? ollamaModel
    }

    /// Returns the effective OpenRouter model for analysis.
    var effectiveAnalysisOpenRouterModel: String? {
        analysisOpenRouterModel ?? openRouterModel
    }
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
    case cancelled

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
        case .cancelled:
            return "Processing was cancelled"
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
