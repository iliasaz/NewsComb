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

    // MARK: - Chunk Pool Types

    /// One unit of work for the cross-article chunk pool.
    private struct ChunkJob: Sendable {
        let articleID: Int64
        let chunk: TextChunk
    }

    /// Outcome of extracting one chunk. `graph == nil` means the chunk produced
    /// nothing (empty extraction or skipped after exhausting attempts).
    private struct ChunkResult: Sendable {
        let articleID: Int64
        let graph: Hypergraph<String, String>?
        let metadata: [ChunkMetadata]
    }

    /// Main-actor-only accumulator for one article's chunks. Folded in serially
    /// by the pool's drain loop; persisted once `outstanding` reaches zero.
    private struct ArticleProgress {
        let item: FeedItem
        let content: String
        let chunkIndex: ChunkIndex
        let totalChunks: Int
        var outstanding: Int
        var graph: Hypergraph<String, String>
        var metadata: [ChunkMetadata]
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
            // Unprocessed = anything not 'completed'. This must include
            // 'pending' (articles the chunk pool reset after a cancel) and
            // 'processing' (rows left stale by a hard kill / SIGKILL mid-run,
            // since only one run executes at a time) — otherwise those articles
            // are silently skipped forever. Only 'completed' is truly done.
            let sql = """
                SELECT fi.*
                FROM feed_item fi
                LEFT JOIN article_hypergraph ah ON fi.id = ah.feed_item_id
                WHERE fi.full_content IS NOT NULL
                  AND fi.full_content != ''
                  AND (ah.id IS NULL OR ah.processing_status != 'completed')
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

            // Cancellation gate: if Stop was pressed while the LLM was running,
            // drop everything we just extracted and reset to .pending. The
            // FoundationModels XPC call doesn't observe Task cancellation, so
            // this is the first checkpoint after it returns — and it MUST run
            // before any database writes so the article boundary stays atomic.
            try Task.checkCancellation()
            if isCancelled { throw CancellationError() }

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
        } catch is CancellationError {
            // User pressed Stop. Reset to .pending so this article is eligible
            // again on the next run, instead of being marked .failed.
            logger.info("Article \(feedItemId) cancelled mid-flight; resetting to pending")
            try? updateProcessingStatus(feedItemId: feedItemId, status: .pending)
            throw CancellationError()
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

    /// Extracts one chunk for the cross-article pool, mapping the outcome to a
    /// `ChunkResult` tagged with its article. Re-throws `CancellationError` so
    /// the enclosing `ThrowingTaskGroup` unwinds promptly.
    ///
    /// Retry policy is provider-aware via `maxAttempts`: on-device passes 1
    /// (skip-and-log on failure, since failures there are deterministic), while
    /// network providers pass >1 with backoff to ride out transient errors. A
    /// chunk that exhausts its attempts returns a nil graph (no events) so its
    /// article still completes with whatever other chunks produced.
    nonisolated private func runChunk(
        _ job: ChunkJob,
        extractor: HypergraphExtractor,
        maxAttempts: Int
    ) async throws -> ChunkResult {
        var attempt = 0
        while true {
            attempt += 1
            do {
                let (graph, metadata) = try await extractor.extractFromChunk(job.chunk)
                return ChunkResult(articleID: job.articleID, graph: graph, metadata: metadata)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                if attempt >= maxAttempts {
                    logger.warning("Chunk failed (attempt \(attempt)/\(maxAttempts)), skipping — article \(job.articleID): \(error.localizedDescription, privacy: .public)")
                    return ChunkResult(articleID: job.articleID, graph: nil, metadata: [])
                }
                logger.notice("Chunk failed (attempt \(attempt)/\(maxAttempts)), retrying — article \(job.articleID): \(error.localizedDescription, privacy: .public)")
                // Backoff; cancellation during the sleep propagates out.
                try await Task.sleep(for: .seconds(Double(attempt) * 2))
            }
        }
    }

    /// Persists a completed article's accumulated graph and marks it `.completed`.
    /// Mirrors the persist tail of `processArticle`, including the cancellation
    /// gate that ensures we never write a partial article after Stop.
    @MainActor
    private func persistArticleResult(
        item: FeedItem,
        content: String,
        result: ProcessingResult,
        chunkCount: Int,
        settings: LLMSettings
    ) async throws {
        guard let id = item.id else { return }
        try Task.checkCancellation()
        if isCancelled { throw CancellationError() }
        try await persistHypergraph(result: result, feedItemId: id, content: content, settings: settings)
        try updateProcessingStatus(feedItemId: id, status: .completed, chunkCount: chunkCount)
    }

    /// Drops a single article's downstream hypergraph state and re-runs

    /// Drops a single article's downstream hypergraph state and re-runs
    /// per-article extraction. Use this when the article body changed and the
    /// caller wants the graph to reflect the new body cleanly, instead of the
    /// union of old + new orphaned by the batch path's upsert behavior.
    ///
    /// Steps (all deletes happen inside one write transaction; extraction
    /// follows after the transaction commits):
    ///   1. Drop provenance rows owned by this article.
    ///   2. Drop edges sourced from this article's chunks (cascades incidences
    ///      and any remaining provenance for those edges).
    ///   3. Drop globally-orphaned nodes (no remaining incidences).
    ///   4. Drop the article's chunks.
    ///   5. Drop the `article_hypergraph` tracking row so re-extraction starts clean.
    @MainActor
    func reprocessArticle(feedItemId: Int64, detailCallback: DetailCallback? = nil) async throws -> ReprocessOutcome {
        logger.info("Reprocessing article \(feedItemId): dropping downstream graph state")

        let startTime = Date()
        let deletionStats = try database.write { db in
            try Self.deleteArticleGraphState(db: db, feedItemId: feedItemId)
        }
        logger.info(
            "Reprocess deletes: \(deletionStats.chunksDeleted) chunks, \(deletionStats.edgesDeleted) edges, \(deletionStats.orphanNodesDeleted) orphan nodes, \(deletionStats.provenanceDeleted) provenance rows"
        )

        try await processArticle(feedItemId: feedItemId, detailCallback: detailCallback)

        let chunksAdded = try database.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM article_chunk WHERE feed_item_id = ?",
                arguments: [feedItemId]
            ) ?? 0
        }
        let edgesAdded = try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*) FROM hypergraph_edge
                    WHERE source_chunk_id IN (SELECT id FROM article_chunk WHERE feed_item_id = ?)
                """,
                arguments: [feedItemId]
            ) ?? 0
        }
        let nodesAdded = try database.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(DISTINCT i.node_id)
                    FROM hypergraph_incidence i
                    JOIN hypergraph_edge e ON e.id = i.edge_id
                    WHERE e.source_chunk_id IN (SELECT id FROM article_chunk WHERE feed_item_id = ?)
                """,
                arguments: [feedItemId]
            ) ?? 0
        }
        let elapsedMs = Int(Date().timeIntervalSince(startTime) * 1000)

        return ReprocessOutcome(
            feedItemId: feedItemId,
            chunksAdded: chunksAdded,
            nodesAdded: nodesAdded,
            edgesAdded: edgesAdded,
            processingTimeMs: elapsedMs,
            deletionStats: deletionStats
        )
    }

    /// Performs the surgical delete chain inside a write transaction. Exposed
    /// as a static helper so unit tests can exercise it against an in-memory
    /// `DatabaseQueue` without touching `Database.current`. Must be called
    /// inside a write transaction; `Database.write { ... }` runs the closure
    /// as a single transaction.
    static func deleteArticleGraphState(db: GRDB.Database, feedItemId: Int64) throws -> ReprocessDeletionStats {
        // 1. Provenance rows owned by this article.
        try db.execute(
            sql: "DELETE FROM article_edge_provenance WHERE feed_item_id = ?",
            arguments: [feedItemId]
        )
        let provenanceDeleted = db.changesCount

        // 2. Edges sourced from this article's chunks. We capture their IDs
        //    first so we can clean up the vec0-backed `event_vectors` and the
        //    cluster-assignment table, neither of which has FK cascades.
        //    `hypergraph_incidence` and remaining `article_edge_provenance`
        //    rows DO cascade via real FKs.
        let edgeIds: [Int64] = try Int64.fetchAll(
            db,
            sql: """
                SELECT id FROM hypergraph_edge
                WHERE source_chunk_id IN (SELECT id FROM article_chunk WHERE feed_item_id = ?)
            """,
            arguments: [feedItemId]
        )
        if !edgeIds.isEmpty {
            // vec0 virtual tables don't support bulk IN-clause deletes — each
            // event_id must be deleted by its own statement. Same constraint
            // is enforced in `SettingsViewModel.deleteSource` and
            // `MainViewModel.resetKnowledgeGraph`.
            for edgeId in edgeIds {
                try db.execute(
                    sql: "DELETE FROM event_vectors WHERE event_id = ?",
                    arguments: [edgeId]
                )
            }
            let placeholders = Array(repeating: "?", count: edgeIds.count).joined(separator: ",")
            let args = StatementArguments(edgeIds)
            try db.execute(
                sql: "DELETE FROM event_cluster WHERE event_id IN (\(placeholders))",
                arguments: args
            )
            try db.execute(
                sql: "DELETE FROM hypergraph_edge WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
        let edgesDeleted = edgeIds.count

        // 3. Globally orphan nodes. `node_embedding` is a vec0 virtual table
        //    with no FK cascade, so its rows must be deleted explicitly;
        //    `node_embedding_metadata` cascades on `hypergraph_node` deletion.
        let orphanNodeIds: [Int64] = try Int64.fetchAll(
            db,
            sql: """
                SELECT id FROM hypergraph_node
                WHERE id NOT IN (SELECT DISTINCT node_id FROM hypergraph_incidence)
            """
        )
        if !orphanNodeIds.isEmpty {
            for nodeId in orphanNodeIds {
                try db.execute(
                    sql: "DELETE FROM node_embedding WHERE node_id = ?",
                    arguments: [nodeId]
                )
            }
            let placeholders = Array(repeating: "?", count: orphanNodeIds.count).joined(separator: ",")
            let args = StatementArguments(orphanNodeIds)
            try db.execute(
                sql: "DELETE FROM hypergraph_node WHERE id IN (\(placeholders))",
                arguments: args
            )
        }
        let orphanNodesDeleted = orphanNodeIds.count

        // 4. Chunks. `chunk_embedding` is a vec0 virtual table with no FK
        //    cascade — clean its rows first. `chunk_embedding_metadata`
        //    cascades on `article_chunk` deletion.
        let chunkIds: [Int64] = try Int64.fetchAll(
            db,
            sql: "SELECT id FROM article_chunk WHERE feed_item_id = ?",
            arguments: [feedItemId]
        )
        for chunkId in chunkIds {
            try db.execute(
                sql: "DELETE FROM chunk_embedding WHERE chunk_id = ?",
                arguments: [chunkId]
            )
        }
        try db.execute(
            sql: "DELETE FROM article_chunk WHERE feed_item_id = ?",
            arguments: [feedItemId]
        )
        let chunksDeleted = chunkIds.count

        // 5. Tracking row. Without this, the unprocessed-articles query won't
        //    pick the article up again on subsequent batch runs.
        try db.execute(
            sql: "DELETE FROM article_hypergraph WHERE feed_item_id = ?",
            arguments: [feedItemId]
        )

        return ReprocessDeletionStats(
            chunksDeleted: chunksDeleted,
            edgesDeleted: edgesDeleted,
            orphanNodesDeleted: orphanNodesDeleted,
            provenanceDeleted: provenanceDeleted
        )
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

        // Build the extraction provider once and reuse it across every chunk.
        let cfg = try makeExtractionConfig(settings: settings)
        let extractor = HypergraphExtractor(
            llmProvider: cfg.provider,
            model: cfg.model,
            chunkSize: cfg.chunkSize,
            distillByDefault: cfg.distill,
            extractionSystemPrompt: cfg.extractionPrompt,
            distillationSystemPrompt: cfg.distillationPrompt
        )
        let splitter = RecursiveTextSplitter(chunkSize: cfg.chunkSize, chunkOverlap: 0)

        // Split every pending article up front into a flat, cross-article chunk
        // job list plus a per-article accumulator. The accumulator lives here on
        // the main actor; the drain loop below mutates it serially between
        // awaits, so no extra actor (and no choke point) is introduced — only
        // the chunk extraction calls fan out concurrently.
        var jobs: [ChunkJob] = []
        var progress: [Int64: ArticleProgress] = [:]
        for article in articles {
            guard let id = article.id, let content = article.fullContent, !content.isEmpty else { continue }
            try updateProcessingStatus(feedItemId: id, status: .processing)

            let chunks = splitter.split(content)
            guard !chunks.isEmpty else {
                // Nothing to extract — mark completed (0 chunks) so it isn't reprocessed.
                try updateProcessingStatus(feedItemId: id, status: .completed, chunkCount: 0)
                continue
            }
            progress[id] = ArticleProgress(
                item: article,
                content: content,
                chunkIndex: ChunkIndex(chunks: chunks),
                totalChunks: chunks.count,
                outstanding: chunks.count,
                graph: Hypergraph(),
                metadata: []
            )
            for chunk in chunks { jobs.append(ChunkJob(articleID: id, chunk: chunk)) }
        }

        let totalArticles = progress.count
        let totalChunks = jobs.count
        var completedArticles = 0
        var completedChunks = 0
        logger.info("Chunk pool: \(totalChunks) chunks across \(totalArticles) articles, window=\(maxConcurrent), attempts/chunk=\(cfg.maxChunkAttempts)")

        // Report progress at chunk granularity so the bar advances continuously.
        // Article-level progress is too coarse here: one long article (many
        // chunks) would leave the bar at 0 until all its chunks finish.
        progressCallback?(0, totalChunks, "Starting\u{2026}")

        // Sliding-window chunk pool: keep up to maxConcurrent chunk extractions
        // in flight regardless of which article they belong to. A slow or empty
        // chunk frees its slot immediately, so one long article no longer
        // serializes the whole pipeline. ThrowingTaskGroup unwinds promptly on
        // cancellation (rethrown CancellationError cancels the remaining
        // children); their in-flight LLM call still runs to completion.
        do {
            try await withThrowingTaskGroup(of: ChunkResult.self) { group in
                var iterator = jobs.makeIterator()

                var active = 0
                while active < maxConcurrent, let job = iterator.next() {
                    group.addTask { try await self.runChunk(job, extractor: extractor, maxAttempts: cfg.maxChunkAttempts) }
                    active += 1
                }

                while let result = try await group.next() {
                    if var ap = progress[result.articleID] {
                        if let graph = result.graph {
                            ap.graph.formUnion(graph)
                            ap.metadata.append(contentsOf: result.metadata)
                        }
                        ap.outstanding -= 1

                        // Chunk-level progress: advances on every chunk, with the
                        // title of the article that chunk belongs to.
                        completedChunks += 1
                        progressCallback?(completedChunks, totalChunks, ap.item.title)

                        if ap.outstanding == 0 {
                            // Last chunk for this article — persist it. Keep it in
                            // `progress` until persist succeeds so a cancel mid-persist
                            // still resets it to .pending below.
                            let pr = ProcessingResult(
                                hypergraph: ap.graph,
                                metadata: ap.metadata,
                                embeddings: NodeEmbeddings(),
                                chunkIndex: ap.chunkIndex,
                                documentID: "\(result.articleID)"
                            )
                            do {
                                try await persistArticleResult(item: ap.item, content: ap.content, result: pr, chunkCount: ap.totalChunks, settings: settings)
                                progress[result.articleID] = nil
                                completedArticles += 1
                                logger.info("Completed \(completedArticles)/\(totalArticles) articles: \(ap.item.title, privacy: .public) — \(pr.nodeCount) nodes, \(pr.edgeCount) edges")
                                // Surface the finished article's top entities so the
                                // UI reflects articles crossing the finish line.
                                detailCallback?(.init(kind: .entitiesExtracted(
                                    articleTitle: ap.item.title,
                                    entities: Array(ap.graph.nodes.prefix(8))
                                )))
                            } catch is CancellationError {
                                throw CancellationError()
                            } catch {
                                logger.error("Persist failed for article \(result.articleID): \(error.localizedDescription, privacy: .public)")
                                try? updateProcessingStatus(feedItemId: result.articleID, status: .failed, errorMessage: error.localizedDescription)
                                progress[result.articleID] = nil
                            }
                        } else {
                            progress[result.articleID] = ap
                        }
                    }

                    if isCancelled {
                        throw CancellationError()
                    }

                    if let job = iterator.next() {
                        group.addTask { try await self.runChunk(job, extractor: extractor, maxAttempts: cfg.maxChunkAttempts) }
                    }
                }
            }
        } catch is CancellationError {
            // Discard partial work: any article still in `progress` never fully
            // persisted, so reset it to .pending to be re-extracted next run.
            let resetCount = progress.count
            for id in progress.keys {
                try? updateProcessingStatus(feedItemId: id, status: .pending)
            }
            logger.info("Processing cancelled after \(completedArticles) articles; reset \(resetCount) partially-processed articles to pending")
            progressCallback?(completedArticles, totalArticles, "Cancelled")
            throw HypergraphServiceError.cancelled
        }

        logger.info("Processing complete: \(completedArticles)/\(totalArticles) articles processed")
        return completedArticles
    }

    // MARK: - Document Processor Creation

    @MainActor
    private func createDocumentProcessor() async throws -> DocumentProcessor {
        let settings = try loadSettings()
        let cfg = try makeExtractionConfig(settings: settings)

        // DocumentProcessor requires an OllamaService for its internal embedding
        // pipeline. Those embeddings are discarded in persistHypergraph and
        // re-generated via the configured embedding provider (Nomic / OpenRouter).
        let placeholderEndpoint = settings.ollamaEndpoint ?? AppSettings.defaultOllamaEndpoint
        let placeholderHost = URL(string: placeholderEndpoint) ?? URL(string: AppSettings.defaultOllamaEndpoint)!
        let embeddingOllama = OllamaService(host: placeholderHost)

        return DocumentProcessor(
            llmProvider: cfg.provider,
            ollamaService: embeddingOllama,
            chatModel: cfg.model,
            chunkSize: cfg.chunkSize,
            distillByDefault: cfg.distill,
            extractionSystemPrompt: cfg.extractionPrompt,
            distillationSystemPrompt: cfg.distillationPrompt
        )
    }

    /// Resolved extraction configuration for the active provider — the single
    /// source of truth shared by `createDocumentProcessor` (single-article
    /// reprocess path) and the chunk pool (`processUnprocessedArticles`).
    private struct ExtractionConfig {
        let provider: any LLMProvider
        let model: String
        let chunkSize: Int
        let distill: Bool
        let extractionPrompt: String?
        let distillationPrompt: String?
        /// Per-chunk extraction attempts: 1 for on-device (skip-and-log on
        /// failure — deterministic, no point retrying), >1 for network
        /// providers (ride out transient errors with backoff).
        let maxChunkAttempts: Int
    }

    @MainActor
    private func makeExtractionConfig(settings: LLMSettings) throws -> ExtractionConfig {
        logger.info("LLM Provider: \(settings.provider, privacy: .public), Embedding: \(settings.embeddingProvider, privacy: .public), distill=\(settings.distillationEnabled, privacy: .public)")

        switch settings.provider {
        case "ollama":
            let endpoint = settings.ollamaEndpoint ?? AppSettings.defaultOllamaEndpoint
            let model = settings.ollamaModel ?? AppSettings.defaultOllamaModel
            let host = URL(string: endpoint) ?? URL(string: AppSettings.defaultOllamaEndpoint)!
            let ollama = OllamaService(host: host, chatModel: model, temperature: settings.extractionTemperature)
            logger.info("Configuring Ollama: endpoint=\(endpoint, privacy: .public), model=\(model, privacy: .public)")
            return ExtractionConfig(
                provider: LoggingLLMProvider(wrapping: ollama),
                model: model,
                chunkSize: 1000,
                distill: settings.distillationEnabled,
                extractionPrompt: settings.extractionSystemPrompt,
                distillationPrompt: settings.distillationSystemPrompt,
                maxChunkAttempts: 3
            )

        case "openrouter":
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                logger.error("OpenRouter API key is missing")
                throw HypergraphServiceError.missingAPIKey
            }
            let chatModel = settings.openRouterModel ?? AppSettings.defaultOpenRouterModel
            let openRouter = try OpenRouterService(apiKey: apiKey, model: chatModel, temperature: settings.extractionTemperature)
            logger.info("Configuring OpenRouter: model=\(chatModel, privacy: .public)")
            return ExtractionConfig(
                provider: LoggingLLMProvider(wrapping: openRouter),
                model: chatModel,
                chunkSize: 1000,
                distill: settings.distillationEnabled,
                extractionPrompt: settings.extractionSystemPrompt,
                distillationPrompt: settings.distillationSystemPrompt,
                maxChunkAttempts: 3
            )

        case "on_device":
            guard case .available = FoundationModelAvailability.check() else {
                logger.error("On-device Foundation Model is not available")
                throw HypergraphServiceError.noProviderConfigured
            }
            let extractionPrompt = settings.extractionSystemPrompt ?? AppSettings.defaultOnDeviceExtractionPrompt
            logger.info("Configuring on-device Foundation Model: chunkSize=\(settings.onDeviceChunkSize)")
            return ExtractionConfig(
                provider: LoggingLLMProvider(wrapping: FoundationModelService()),
                model: "apple-on-device",
                chunkSize: settings.onDeviceChunkSize,
                distill: settings.distillationEnabled,
                extractionPrompt: extractionPrompt,
                distillationPrompt: settings.distillationSystemPrompt,
                maxChunkAttempts: 1
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

            // Distillation toggle (stored as "true"/"false" string)
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.distillationEnabled)
                .fetchOne(db),
               let value = Bool(setting.value) {
                settings.distillationEnabled = value
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

    /// Whether per-chunk distillation runs before entity extraction.
    var distillationEnabled: Bool = AppSettings.defaultDistillationEnabled

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

/// Counts of rows deleted by `HypergraphService.deleteArticleGraphState`.
/// `orphanNodesDeleted` is a global sweep — it counts every node whose
/// remaining incidence count fell to zero, which may include nodes orphaned
/// by previous reprocesses, not just by this article.
struct ReprocessDeletionStats: Sendable, Equatable {
    let chunksDeleted: Int
    let edgesDeleted: Int
    let orphanNodesDeleted: Int
    let provenanceDeleted: Int
}

/// Result returned from `HypergraphService.reprocessArticle`. The `*Added`
/// fields are post-reprocess counts scoped to this article, since the delete
/// chain brought the article's graph state to zero before re-extraction ran.
struct ReprocessOutcome: Sendable {
    let feedItemId: Int64
    let chunksAdded: Int
    let nodesAdded: Int
    let edgesAdded: Int
    let processingTimeMs: Int
    let deletionStats: ReprocessDeletionStats
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
