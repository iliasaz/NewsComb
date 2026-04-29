import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Service for extracting and persisting hypergraph knowledge from articles.
final class HypergraphService: Sendable {

    private let database = Database.current
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

    /// Fine-grained processing detail for per-article feedback.
    struct ProcessingDetail: Sendable {
        enum Kind: Sendable {
            case articleStarted(title: String)
            case entitiesExtracted(articleTitle: String, entities: [String])
        }
        let kind: Kind
    }

    /// Callback for per-article processing details.
    typealias DetailCallback = @MainActor @Sendable (ProcessingDetail) -> Void

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

                // Check for on-device Foundation Models provider
                if let providerSetting = try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.llmProvider)
                    .fetchOne(db),
                   providerSetting.value == "on_device" {
                    if case .available = FoundationModelAvailability.check() {
                        return true
                    }
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
    func processArticle(feedItemId: Int64, detailCallback: DetailCallback? = nil) async throws {
        logger.info("Starting to process article \(feedItemId)")

        // Get the feed item
        guard let feedItem = try database.read({ db in
            try FeedItem.filter(FeedItem.Columns.id == feedItemId).fetchOne(db)
        }) else {
            logger.error("Article \(feedItemId) not found in database")
            throw HypergraphServiceError.articleNotFound
        }

        logger.info("Found article: \(feedItem.title, privacy: .public)")

        // Notify that this article has started processing
        detailCallback?(.init(kind: .articleStarted(title: feedItem.title)))

        guard let content = feedItem.fullContent, !content.isEmpty else {
            logger.warning("Article \(feedItemId) has no content")
            throw HypergraphServiceError.noContent
        }

        logger.info("Article content length: \(content.count) characters")

        // Mark as processing
        try updateProcessingStatus(feedItemId: feedItemId, status: .processing)
        logger.debug("Marked article \(feedItemId) as processing")

        do {
            // Bail early if this task was cancelled
            try Task.checkCancellation()

            // Create document processor
            logger.info("Creating document processor...")
            let processor = try await createDocumentProcessor()
            logger.info("Document processor created successfully")

            // Extract the hypergraph structure only — embedding generation is
            // handled by persistHypergraph() using the configured provider.
            logger.info("Processing text with HyperGraphReasoning...")
            let startTime = Date()
            let result = try await processor.processText(
                content,
                documentID: "\(feedItemId)",
                generateEmbeddings: false
            )
            let processingTime = Date().timeIntervalSince(startTime)
            logger.info("Text processing completed in \(String(format: "%.2f", processingTime))s")

            // Log hypergraph statistics
            let nodeCount = result.hypergraph.nodes.count
            let edgeCount = result.hypergraph.incidenceDict.count
            let embeddingCount = result.embeddings.embeddings.count
            let chunkCount = result.metadata.allChunkIDs.count
            logger.info("Extracted hypergraph: \(nodeCount) nodes, \(edgeCount) edges, \(embeddingCount) embeddings, \(chunkCount) chunks")

            // Notify about extracted entities (up to 8 representative nodes)
            let extractedEntities = Array(result.hypergraph.nodes.prefix(8))
            detailCallback?(.init(kind: .entitiesExtracted(
                articleTitle: feedItem.title,
                entities: extractedEntities
            )))

            // Log some sample nodes
            let sampleNodes = result.hypergraph.nodes.prefix(5)
            logger.debug("Sample nodes: \(sampleNodes.joined(separator: ", "), privacy: .public)")

            // Persist the hypergraph and generate embeddings
            logger.info("Persisting hypergraph to database...")
            let settings = try loadSettings()
            try await persistHypergraph(result: result, feedItemId: feedItemId, content: content, settings: settings)
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
    func processUnprocessedArticles(progressCallback: ProgressCallback?, detailCallback: DetailCallback? = nil) async throws -> Int {
        resetCancellation()

        // If the graph is empty, ensure vec0 tables match the current dimension setting.
        // This handles the case where the user changed the dimension in Settings
        // and then starts processing without doing a manual graph reset.
        try ensureVec0TablesMatchDimension()

        let articles = try getUnprocessedArticles()
        logger.info("Found \(articles.count) unprocessed articles")

        guard !articles.isEmpty else {
            logger.info("No articles to process")
            return 0
        }

        let settings = try loadSettings()
        let maxConcurrent = settings.maxConcurrentProcessing

        // Pre-download the embedding model before spawning concurrent tasks.
        // This avoids a race where multiple tasks try to download simultaneously.
        if settings.embeddingProvider != "openrouter" {
            logger.info("Ensuring Nomic embedding model is downloaded before processing")
            try await NomicEmbeddingService.shared.ensureModelLoaded()
        }

        let totalCount = articles.count
        var processedCount = 0
        var failedCount = 0

        logger.info("Starting parallel processing with max \(maxConcurrent) concurrent tasks")

        // Process articles in batches. Failed articles are collected and retried
        // in subsequent passes with increasing delay, so they don't block the
        // main processing queue during backoff waits.
        var pendingArticles = articles
        var completedSoFar = 0
        let maxRetryPasses = 3
        let retryDelays: [Duration] = [.seconds(10), .seconds(30), .seconds(60)]

        for pass in 0...maxRetryPasses {
            guard !pendingArticles.isEmpty else { break }

            if pass > 0 {
                let delay = retryDelays[min(pass - 1, retryDelays.count - 1)]
                logger.info("Retry pass \(pass)/\(maxRetryPasses): \(pendingArticles.count) articles after \(delay) delay")
                progressCallback?(completedSoFar, totalCount, "Retrying \(pendingArticles.count) failed articles\u{2026}")
                try await Task.sleep(for: delay)
            }

            let batches = pendingArticles.chunked(into: maxConcurrent)
            var failedThisPass: [FeedItem] = []

            for batch in batches {
                if isCancelled {
                    logger.info("Processing cancelled after \(completedSoFar) articles")
                    progressCallback?(completedSoFar, totalCount, "Cancelled")
                    throw HypergraphServiceError.cancelled
                }

                // Use ThrowingTaskGroup so CancellationError exits immediately
                // without waiting for in-flight HTTP requests to time out.
                let results: [(FeedItem, Bool)]
                do {
                    results = try await withThrowingTaskGroup(
                        of: (FeedItem, Bool).self,
                        returning: [(FeedItem, Bool)].self
                    ) { group in
                        for article in batch {
                            guard article.id != nil else { continue }
                            group.addTask {
                                do {
                                    try await self.processArticle(
                                        feedItemId: article.id!,
                                        detailCallback: detailCallback
                                    )
                                    return (article, true)
                                } catch is CancellationError {
                                    throw CancellationError()
                                } catch {
                                    self.logger.warning("Article failed: \(article.title, privacy: .public) — \(error.localizedDescription, privacy: .public)")
                                    return (article, false)
                                }
                            }
                        }

                        var batchResults: [(FeedItem, Bool)] = []
                        for try await result in group {
                            batchResults.append(result)
                            if self.isCancelled {
                                throw CancellationError()
                            }
                        }
                        return batchResults
                    }
                } catch is CancellationError {
                    logger.info("Processing cancelled after \(completedSoFar) articles")
                    progressCallback?(completedSoFar, totalCount, "Cancelled")
                    throw HypergraphServiceError.cancelled
                }

                for (article, success) in results {
                    completedSoFar += 1
                    if success {
                        processedCount += 1
                        logger.info("Completed \(completedSoFar)/\(totalCount): \(article.title, privacy: .public) - SUCCESS")
                    } else {
                        failedCount += 1
                        failedThisPass.append(article)
                        logger.warning("Completed \(completedSoFar)/\(totalCount): \(article.title, privacy: .public) - FAILED")
                    }
                    progressCallback?(completedSoFar, totalCount, article.title)
                }
            }

            // Set up next retry pass with only the failures
            pendingArticles = failedThisPass

            if !failedThisPass.isEmpty && pass < maxRetryPasses {
                // Subtract failures from completedSoFar so they count again on retry
                completedSoFar -= failedThisPass.count
                failedCount -= failedThisPass.count
                logger.info("Pass \(pass) complete: \(failedThisPass.count) articles will be retried")
            }
        }

        logger.info("Processing complete: \(processedCount) succeeded, \(failedCount) failed out of \(totalCount) total")
        return processedCount
    }

    // MARK: - Document Processor Creation

    @MainActor
    private func createDocumentProcessor() async throws -> DocumentProcessor {
        let settings = try loadSettings()
        logger.info("LLM Provider: \(settings.provider, privacy: .public)")
        logger.info("Embedding Provider: \(settings.embeddingProvider, privacy: .public)")

        // DocumentProcessor requires an OllamaService for its internal embedding pipeline.
        // The embeddings it produces are discarded in persistHypergraph and re-generated
        // via the configured embedding provider (Nomic on-device or OpenRouter).
        let placeholderEndpoint = settings.ollamaEndpoint ?? AppSettings.defaultOllamaEndpoint
        let placeholderHost = URL(string: placeholderEndpoint) ?? URL(string: AppSettings.defaultOllamaEndpoint)!
        let embeddingOllama = OllamaService(host: placeholderHost)

        switch settings.provider {
        case "ollama":
            let endpoint = settings.ollamaEndpoint ?? AppSettings.defaultOllamaEndpoint
            let model = settings.ollamaModel ?? AppSettings.defaultOllamaModel
            logger.info("Configuring Ollama: endpoint=\(endpoint, privacy: .public), model=\(model, privacy: .public)")

            if let extractionPrompt = settings.extractionSystemPrompt {
                logger.info("Using custom extraction prompt (\(extractionPrompt.count) chars)")
            }

            let host = URL(string: endpoint) ?? URL(string: AppSettings.defaultOllamaEndpoint)!
            let ollama = OllamaService(
                host: host,
                chatModel: model,
                temperature: settings.extractionTemperature
            )
            return DocumentProcessor(
                llmProvider: LoggingLLMProvider(wrapping: ollama),
                ollamaService: ollama,
                chatModel: model,
                extractionSystemPrompt: settings.extractionSystemPrompt,
                distillationSystemPrompt: settings.distillationSystemPrompt
            )

        case "openrouter":
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                logger.error("OpenRouter API key is missing")
                throw HypergraphServiceError.missingAPIKey
            }
            let chatModel = settings.openRouterModel ?? AppSettings.defaultOpenRouterModel
            logger.info("Configuring OpenRouter: model=\(chatModel, privacy: .public)")

            if let extractionPrompt = settings.extractionSystemPrompt {
                logger.info("Using custom extraction prompt (\(extractionPrompt.count) chars)")
            }

            let openRouter = try OpenRouterService(
                apiKey: apiKey,
                model: chatModel,
                temperature: settings.extractionTemperature
            )

            return DocumentProcessor(
                llmProvider: LoggingLLMProvider(wrapping: openRouter),
                ollamaService: embeddingOllama,
                chatModel: chatModel,
                extractionSystemPrompt: settings.extractionSystemPrompt,
                distillationSystemPrompt: settings.distillationSystemPrompt
            )

        case "on_device":
            guard case .available = FoundationModelAvailability.check() else {
                logger.error("On-device Foundation Model is not available")
                throw HypergraphServiceError.noProviderConfigured
            }
            let service = FoundationModelService()
            let extractionPrompt = settings.extractionSystemPrompt
                ?? AppSettings.defaultOnDeviceExtractionPrompt
            let chunkSize = settings.onDeviceChunkSize
            logger.info("Configuring on-device Foundation Model: chunkSize=\(chunkSize)")

            return DocumentProcessor(
                llmProvider: LoggingLLMProvider(wrapping: service),
                ollamaService: embeddingOllama,
                chatModel: "apple-on-device",
                chunkSize: chunkSize,
                extractionSystemPrompt: extractionPrompt,
                distillationSystemPrompt: settings.distillationSystemPrompt
            )

        default:
            logger.error("No LLM provider configured (provider value: '\(settings.provider, privacy: .public)')")
            throw HypergraphServiceError.noProviderConfigured
        }
    }

    /// Generates an embedding for the given text using the configured provider.
    @MainActor
    private func embedText(_ text: String, settings: LLMSettings) async throws -> [Float] {
        if settings.embeddingProvider == "openrouter" {
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                throw HypergraphServiceError.noProviderConfigured
            }
            let model = settings.embeddingOpenRouterModel ?? AppSettings.defaultEmbeddingOpenRouterModel
            let service = OpenRouterEmbeddingService(
                apiKey: apiKey,
                model: model,
                dimensions: settings.embeddingDimension
            )
            logger.info("Embedding via OpenRouter: model=\(model, privacy: .public), dim=\(settings.embeddingDimension)")
            return try await service.embed(text)
        } else {
            logger.info("Embedding via on-device Nomic: \(NomicEmbeddingService.modelName, privacy: .public)")
            return try await NomicEmbeddingService.shared.embed(text)
        }
    }

    /// Generates embeddings for multiple texts using the configured provider.
    @MainActor
    private func embedTexts(_ texts: [String], settings: LLMSettings) async throws -> [[Float]] {
        if settings.embeddingProvider == "openrouter" {
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                throw HypergraphServiceError.noProviderConfigured
            }
            let model = settings.embeddingOpenRouterModel ?? AppSettings.defaultEmbeddingOpenRouterModel
            let service = OpenRouterEmbeddingService(
                apiKey: apiKey,
                model: model,
                dimensions: settings.embeddingDimension
            )
            return try await service.embed(texts)
        } else {
            return try await NomicEmbeddingService.shared.embed(texts)
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
                // Migrate legacy "ollama" provider to "nomic"
                settings.embeddingProvider = provider.value == "ollama" ? "nomic" : provider.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingOpenRouterModel)
                .fetchOne(db) {
                settings.embeddingOpenRouterModel = model.value
            }

            // Use the provider-aware dimension: Nomic always produces 768-d,
            // OpenRouter uses the user-configured dimension.
            settings.embeddingDimension = try AppSettings.effectiveEmbeddingDimension(db)

            // Temperature configuration
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.extractionTemperature)
                .fetchOne(db),
               let value = Double(setting.value) {
                settings.extractionTemperature = value
            }

            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.analysisTemperature)
                .fetchOne(db),
               let value = Double(setting.value) {
                settings.analysisTemperature = value
            }

            // Processing configuration
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.maxConcurrentProcessing)
                .fetchOne(db),
               let value = Int(setting.value) {
                settings.maxConcurrentProcessing = value
            }

            // On-device chunk size
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.onDeviceChunkSize)
                .fetchOne(db),
               let value = Int(setting.value) {
                settings.onDeviceChunkSize = value
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
            let provider = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.embeddingProvider)
                .fetchOne(db)?.value ?? AppSettings.defaultEmbeddingProvider

            if provider == "openrouter" {
                return try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.embeddingOpenRouterModel)
                    .fetchOne(db)?.value ?? AppSettings.defaultEmbeddingOpenRouterModel
            } else {
                return NomicEmbeddingService.modelName
            }
        }
    }

    // MARK: - Hypergraph Persistence

    private func persistHypergraph(result: ProcessingResult, feedItemId: Int64, content: String, settings: LLMSettings) async throws {
        logger.debug("Beginning hypergraph persistence for article \(feedItemId)")
        var nodesInserted = 0
        var edgesInserted = 0
        var embeddingsStored = 0
        var chunksStored = 0

        // Get embedding model name BEFORE the write transaction to avoid reentrancy
        let embeddingModel = try getEmbeddingModelName()

        // Track nodes that need embeddings (populated inside write, generated after)
        var nodesNeedingEmbeddings: [(nodeLabel: String, nodeRowId: Int64)] = []

        // Use the library's ChunkIndex for provenance tracking.
        // The library identifies chunks by MD5 hash, not sequential index.
        // Build a deterministic ordering so we can assign sequential integer
        // indices for the article_chunk table.
        let libraryChunkIDs = result.chunkIndex.chunkIDs.sorted()

        try database.write { db in
            // Store article chunks keyed by the library's MD5 chunk IDs
            var chunkHashToSequentialIndex: [String: Int] = [:]
            var chunkHashToRowId: [String: Int64] = [:]
            for (index, chunkHash) in libraryChunkIDs.enumerated() {
                guard let chunkContent = result.chunkIndex[chunkHash] else { continue }
                let chunkRowId = try self.upsertArticleChunk(
                    db: db,
                    feedItemId: feedItemId,
                    chunkIndex: index,
                    content: chunkContent
                )
                chunkHashToSequentialIndex[chunkHash] = index
                chunkHashToRowId[chunkHash] = chunkRowId
                chunksStored += 1
            }

            // Process each edge in the hypergraph
            for (edgeId, nodeIds) in result.hypergraph.incidenceDict {
                // Find the metadata for this edge to get the relation
                let edgeMetadata = result.metadata.first { $0.edge == edgeId }
                let relation = edgeMetadata.map { self.extractRelation(from: $0) } ?? "unknown"

                // Look up the chunk row ID via the library's MD5 chunk hash
                let sourceChunkId = edgeMetadata.flatMap { chunkHashToRowId[$0.chunkID] }

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

                // Create provenance link with the actual source chunk text
                if let meta = edgeMetadata {
                    let chunkText = result.chunkIndex[meta.chunkID]
                    let sequentialIndex = chunkHashToSequentialIndex[meta.chunkID] ?? 0
                    try self.upsertProvenance(
                        db: db,
                        edgeId: edgeRowId,
                        feedItemId: feedItemId,
                        chunkIndex: sequentialIndex,
                        chunkText: chunkText
                    )
                }
            }

            self.logger.debug("Persisted \(edgesInserted) edges, \(nodesInserted) node references, \(chunksStored) chunks")

            // Collect nodes that need embeddings from the hypergraph
            var skippedEmbeddings = 0

            for nodeLabel in result.hypergraph.nodes {
                if let node = try HypergraphNode
                    .filter(HypergraphNode.Columns.nodeId == nodeLabel)
                    .fetchOne(db),
                   let nodeRowId = node.id {
                    if try NodeEmbeddingMetadata.hasEmbedding(db, nodeId: nodeRowId) {
                        skippedEmbeddings += 1
                    } else {
                        nodesNeedingEmbeddings.append((nodeLabel: nodeLabel, nodeRowId: nodeRowId))
                    }
                }
            }

            if skippedEmbeddings > 0 {
                self.logger.debug("Skipped \(skippedEmbeddings) embeddings (already exist)")
            }
        }

        // Generate embeddings using the configured provider
        if !nodesNeedingEmbeddings.isEmpty {
            let labels = nodesNeedingEmbeddings.map(\.nodeLabel)
            logger.info("Generating \(labels.count) embeddings via \(settings.embeddingProvider)")

            let embeddings = try await embedTexts(labels, settings: settings)

            try database.write { db in
                for (index, (_, nodeRowId)) in nodesNeedingEmbeddings.enumerated() where index < embeddings.count {
                    try self.storeEmbedding(db: db, nodeId: nodeRowId, embedding: embeddings[index])
                    try NodeEmbeddingMetadata.markEmbeddingComputed(db, nodeId: nodeRowId, modelName: embeddingModel)
                    embeddingsStored += 1
                }
            }
        }

        self.logger.debug("Stored \(embeddingsStored) new embeddings")
        logger.info("Persistence complete: \(edgesInserted) edges, \(nodesInserted) node refs, \(embeddingsStored) embeddings, \(chunksStored) chunks")
    }

    private func extractRelation(from metadata: ChunkMetadata) -> String {
        // Extract a human-readable relation from the edge ID.
        // Use ContextCollector's logic which splits at "_chunk" and takes
        // the prefix, avoiding incorrect suffixes like "works_for_chunk_0".
        if let extracted = ContextCollector.extractRelation(from: metadata.edge) {
            return extracted
        }
        // Fallback: strip leading index component
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
                    INSERT INTO hypergraph_edge (edge_id, label, source_chunk_id, created_at)
                    VALUES (?, ?, ?, unixepoch())
                    ON CONFLICT(edge_id) DO UPDATE SET
                        label = excluded.label,
                        source_chunk_id = COALESCE(excluded.source_chunk_id, source_chunk_id)
                """,
                arguments: [edgeId, relation, chunkId]
            )
        } else {
            try db.execute(
                sql: """
                    INSERT INTO hypergraph_edge (edge_id, label, created_at)
                    VALUES (?, ?, unixepoch())
                    ON CONFLICT(edge_id) DO UPDATE SET
                        label = excluded.label
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

    private func upsertProvenance(db: GRDB.Database, edgeId: Int64, feedItemId: Int64, chunkIndex: Int, chunkText: String?) throws {
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
        let queryEmbedding = try await embedText(query, settings: settings)
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

    // MARK: - Vec0 Table Management

    /// Recreates vec0 virtual tables if the active dimension doesn't match the desired
    /// dimension AND the graph tables are empty. This allows a dimension change to take
    /// effect without requiring a manual graph reset when no data exists yet.
    private func ensureVec0TablesMatchDimension() throws {
        try database.write { db in
            // Derive the desired dimension from the active embedding provider.
            // Nomic always produces 768-d vectors; OpenRouter uses the configured dimension.
            let desiredDim = try AppSettings.effectiveEmbeddingDimension(db)

            let activeDim: Int
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.activeEmbeddingDimension)
                .fetchOne(db),
               let value = Int(setting.value) {
                activeDim = value
            } else {
                activeDim = 0
            }

            guard activeDim != desiredDim else { return }

            // Only recreate if there's no existing graph data
            let nodeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node") ?? 0
            guard nodeCount == 0 else {
                logger.warning("Dimension mismatch (\(activeDim) vs \(desiredDim)) but graph has \(nodeCount) nodes — reset the graph first")
                return
            }

            let eventVecDim = 3 * desiredDim + 12  // 12 = RelationFamily.count
            logger.info("Graph is empty — recreating vec0 tables with dimension \(desiredDim)")

            try db.execute(sql: "DROP TABLE IF EXISTS event_vectors")
            try db.execute(sql: "DROP TABLE IF EXISTS chunk_embedding")
            try db.execute(sql: "DROP TABLE IF EXISTS node_embedding")

            try db.execute(sql: """
                CREATE VIRTUAL TABLE node_embedding USING vec0(
                    node_id INTEGER PRIMARY KEY,
                    embedding float[\(desiredDim)]
                )
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE chunk_embedding USING vec0(
                    chunk_id INTEGER PRIMARY KEY,
                    embedding float[\(desiredDim)]
                )
            """)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE event_vectors USING vec0(
                    event_id INTEGER PRIMARY KEY,
                    vec float[\(eventVecDim)]
                )
            """)

            try db.execute(
                sql: """
                    INSERT INTO app_settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """,
                arguments: [AppSettings.activeEmbeddingDimension, String(desiredDim)]
            )
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

            let personaTypes = AgentProfileService.personaNodeTypes.map { "'\($0)'" }.joined(separator: ", ")
            let personaNodeCount = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM hypergraph_node WHERE LOWER(node_type) IN (\(personaTypes))
                """) ?? 0

            return HypergraphStatistics(
                nodeCount: nodeCount,
                edgeCount: edgeCount,
                processedArticles: processedArticles,
                embeddingCount: embeddingCount,
                personaNodeCount: personaNodeCount
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
    var embeddingProvider: String = "nomic"
    var embeddingOpenRouterModel: String?
    var embeddingDimension: Int = AppSettings.defaultEmbeddingDimension

    // Analysis LLM configuration (for answers and deep analysis)
    // Falls back to main LLM settings if not configured
    var analysisProvider: String?
    var analysisOllamaEndpoint: String?
    var analysisOllamaModel: String?
    var analysisOpenRouterModel: String?

    // Temperature configuration
    var extractionTemperature: Double = Double(AppSettings.defaultExtractionTemperature)
    var analysisTemperature: Double = Double(AppSettings.defaultAnalysisTemperature)

    // Processing configuration
    var maxConcurrentProcessing: Int = AppSettings.defaultMaxConcurrentProcessing

    // On-device chunk size (smaller for 4096-token context window)
    var onDeviceChunkSize: Int = AppSettings.defaultOnDeviceChunkSize

    // Custom prompts (nil means use defaults)
    var extractionSystemPrompt: String?
    var distillationSystemPrompt: String?
    var clusterLabelingPrompt: String?

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
    let personaNodeCount: Int
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

// MARK: - Provenance Repair

extension HypergraphService {

    /// Repairs provenance data in-place without re-running LLM extraction.
    ///
    /// The old code always wrote `chunk_index = 0` because it tried to parse a
    /// sequential integer from the library's MD5 chunk hash. This method:
    /// 1. Re-chunks each affected article with `RecursiveTextSplitter` (matching the library)
    /// 2. Parses the chunk hash from `hypergraph_edge.edge_id`
    /// 3. Updates `article_edge_provenance` with the correct `chunk_index` and `chunk_text`
    /// 4. Refreshes `article_chunk` rows and links `hypergraph_edge.source_chunk_id`
    ///
    /// No LLM calls or embedding recomputation needed.
    func repairProvenance(progressCallback: ProgressCallback? = nil) async throws -> Int {
        // Find articles whose provenance is broken: all chunk_index = 0 but
        // the article actually had multiple chunks.
        let articlesToRepair: [(feedItemId: Int64, content: String)] = try database.read { db in
            try Row.fetchAll(db, sql: """
                SELECT DISTINCT fi.id AS feed_item_id, fi.full_content
                FROM article_edge_provenance aep
                JOIN feed_item fi ON fi.id = aep.feed_item_id
                WHERE fi.full_content IS NOT NULL AND fi.full_content != ''
                GROUP BY fi.id
                HAVING MAX(aep.chunk_index) = 0 AND COUNT(*) > 1
            """).compactMap { row -> (Int64, String)? in
                guard let id: Int64 = row["feed_item_id"],
                      let content: String = row["full_content"],
                      !content.isEmpty else { return nil }
                return (id, content)
            }
        }

        guard !articlesToRepair.isEmpty else {
            logger.info("No provenance to repair")
            return 0
        }

        logger.info("Repairing provenance for \(articlesToRepair.count) articles")
        let splitter = RecursiveTextSplitter(chunkSize: 1000)

        var repairedCount = 0

        for (index, article) in articlesToRepair.enumerated() {
            // Re-chunk with the same splitter the library used
            let chunks = splitter.split(article.content)
            guard !chunks.isEmpty else { continue }

            // Build hash → (sequentialIndex, text) mapping
            var hashToIndex: [String: Int] = [:]
            var hashToText: [String: String] = [:]
            for (seqIdx, chunk) in chunks.enumerated() {
                hashToIndex[chunk.chunkID] = seqIdx
                hashToText[chunk.chunkID] = chunk.text
            }

            try database.write { db in
                // Refresh article_chunk rows with library-aligned chunks
                var chunkIdMap: [String: Int64] = [:]
                for (seqIdx, chunk) in chunks.enumerated() {
                    try db.execute(
                        sql: """
                            INSERT INTO article_chunk (feed_item_id, chunk_index, content, created_at)
                            VALUES (?, ?, ?, unixepoch())
                            ON CONFLICT(feed_item_id, chunk_index) DO UPDATE SET
                                content = excluded.content
                        """,
                        arguments: [article.feedItemId, seqIdx, chunk.text]
                    )
                    if let row = try Row.fetchOne(
                        db,
                        sql: "SELECT id FROM article_chunk WHERE feed_item_id = ? AND chunk_index = ?",
                        arguments: [article.feedItemId, seqIdx]
                    ) {
                        chunkIdMap[chunk.chunkID] = row["id"]
                    }
                }

                // Get all edges for this article via provenance
                let edgeRows = try Row.fetchAll(db, sql: """
                    SELECT DISTINCT he.id AS edge_row_id, he.edge_id
                    FROM article_edge_provenance aep
                    JOIN hypergraph_edge he ON he.id = aep.edge_id
                    WHERE aep.feed_item_id = ?
                """, arguments: [article.feedItemId])

                for edgeRow in edgeRows {
                    guard let edgeRowId: Int64 = edgeRow["edge_row_id"],
                          let edgeId: String = edgeRow["edge_id"] else { continue }

                    // Parse chunk hash from edge_id: "relation_chunk<32-char-hash>_index"
                    guard let chunkRange = edgeId.range(of: "_chunk") else { continue }
                    let afterChunk = edgeId[chunkRange.upperBound...]
                    let chunkHash = String(afterChunk.prefix(32))
                    guard chunkHash.count == 32 else { continue }

                    let seqIdx = hashToIndex[chunkHash] ?? 0
                    let chunkText = hashToText[chunkHash]
                    let sourceChunkRowId = chunkIdMap[chunkHash]

                    // Update provenance with correct chunk_index and chunk_text
                    try db.execute(
                        sql: """
                            UPDATE article_edge_provenance
                            SET chunk_index = ?, chunk_text = ?
                            WHERE edge_id = ? AND feed_item_id = ?
                        """,
                        arguments: [seqIdx, chunkText, edgeRowId, article.feedItemId]
                    )

                    // Link edge to source chunk
                    if let chunkRowId = sourceChunkRowId {
                        try db.execute(
                            sql: "UPDATE hypergraph_edge SET source_chunk_id = ? WHERE id = ?",
                            arguments: [chunkRowId, edgeRowId]
                        )
                    }
                }
            }

            repairedCount += 1
            if let cb = progressCallback {
                await cb(index + 1, articlesToRepair.count, "Repairing provenance…")
            }
        }

        logger.info("Provenance repair complete: \(repairedCount) articles repaired")
        return repairedCount
    }
}

// MARK: - Array Chunking Extension

extension Array {
    /// Splits the array into chunks of the specified size.
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
