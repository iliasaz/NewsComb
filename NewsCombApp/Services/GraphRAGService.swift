import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Service for querying the knowledge graph using RAG (Retrieval-Augmented Generation).
final class GraphRAGService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "GraphRAGService")

    // MARK: - Query

    /// Queries the knowledge graph with a natural language question.
    /// - Parameters:
    ///   - question: The question to answer
    ///   - maxNodes: Maximum number of similar nodes to retrieve
    ///   - maxChunks: Maximum number of relevant chunks to retrieve
    /// - Returns: A GraphRAGResponse containing the answer and sources
    @MainActor
    func query(_ question: String, maxNodes: Int = 10, maxChunks: Int = 5) async throws -> GraphRAGResponse {
        logger.info("GraphRAG query: \(question, privacy: .public)")

        // Step 1: Embed the query
        let queryEmbedding = try await embedQuery(question)
        logger.debug("Query embedded successfully")

        // Step 2: Find similar nodes using sqlite-vec
        let similarNodes = try findSimilarNodes(queryEmbedding: queryEmbedding, limit: maxNodes)
        logger.info("Found \(similarNodes.count) similar nodes")

        // Step 3: Traverse edges from similar nodes to gather context
        let context = try gatherContext(
            fromNodes: similarNodes,
            queryEmbedding: queryEmbedding,
            maxChunks: maxChunks
        )
        logger.info("Gathered context: \(context.relevantEdges.count) edges, \(context.relevantChunks.count) chunks")

        // Step 4: Generate answer using LLM
        let answer = try await generateAnswer(question: question, context: context)
        logger.info("Answer generated successfully")

        // Step 5: Build response with sources and graph paths
        let sourceArticles = try buildSourceArticles(from: context)
        let graphPaths = buildGraphPaths(from: context)

        return GraphRAGResponse(
            query: question,
            answer: answer,
            relatedNodes: similarNodes,
            graphPaths: graphPaths,
            sourceArticles: sourceArticles
        )
    }

    // MARK: - Embedding

    /// Embeds the query text using the configured embedding service.
    @MainActor
    private func embedQuery(_ text: String) async throws -> Data {
        let settings = try loadSettings()
        let ollama = createEmbeddingService(settings: settings)

        let embedding = try await ollama.embed(text)
        return embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }

    // MARK: - Similarity Search

    /// Finds nodes similar to the query using sqlite-vec.
    private func findSimilarNodes(queryEmbedding: Data, limit: Int) throws -> [GraphRAGResponse.RelatedNode] {
        try database.read { db in
            let sql = """
                SELECT hn.id, hn.node_id, hn.label, hn.node_type,
                       vec_distance_L2(ne.embedding, ?) as distance
                FROM hypergraph_node hn
                JOIN node_embedding ne ON hn.id = ne.node_id
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [queryEmbedding, limit])
            return rows.map { row in
                GraphRAGResponse.RelatedNode(
                    id: row["id"],
                    nodeId: row["node_id"],
                    label: row["label"],
                    nodeType: row["node_type"],
                    distance: row["distance"]
                )
            }
        }
    }

    /// Finds chunks similar to the query using sqlite-vec.
    private func findSimilarChunks(queryEmbedding: Data, limit: Int) throws -> [GraphRAGContext.ChunkWithArticle] {
        try database.read { db in
            let sql = """
                SELECT ac.id as chunk_id, ac.chunk_index, ac.content,
                       vec_distance_L2(ce.embedding, ?) as distance,
                       fi.id as article_id, fi.title as article_title
                FROM article_chunk ac
                JOIN chunk_embedding ce ON ac.id = ce.chunk_id
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: [queryEmbedding, limit])
            return rows.map { row in
                GraphRAGContext.ChunkWithArticle(
                    chunkId: row["chunk_id"],
                    chunkIndex: row["chunk_index"],
                    content: row["content"],
                    distance: row["distance"],
                    articleId: row["article_id"],
                    articleTitle: row["article_title"]
                )
            }
        }
    }

    // MARK: - Context Gathering

    /// Gathers context from the knowledge graph based on similar nodes.
    private func gatherContext(
        fromNodes nodes: [GraphRAGResponse.RelatedNode],
        queryEmbedding: Data,
        maxChunks: Int
    ) throws -> GraphRAGContext {
        let nodeIds = nodes.map { $0.id }

        // Get edges connected to the similar nodes
        let edges = try findEdgesForNodes(nodeIds: nodeIds)

        // Find relevant chunks (from chunk embeddings if available, otherwise from provenance)
        var chunks = try findSimilarChunks(queryEmbedding: queryEmbedding, limit: maxChunks)

        // If no chunks from embeddings, fall back to provenance-based chunks
        if chunks.isEmpty {
            chunks = try findChunksFromProvenance(nodeIds: nodeIds, limit: maxChunks)
        }

        return GraphRAGContext(
            relevantNodes: nodes,
            relevantEdges: edges,
            relevantChunks: chunks
        )
    }

    /// Finds edges connected to the given nodes.
    private func findEdgesForNodes(nodeIds: [Int64]) throws -> [GraphRAGContext.ContextEdge] {
        guard !nodeIds.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            // First find edges connected to searched nodes, then get ALL their incidences
            let sql = """
                SELECT he.id, he.relation, aep.chunk_text,
                       GROUP_CONCAT(DISTINCT CASE WHEN hi.role = 'source' THEN hn.label END) as sources,
                       GROUP_CONCAT(DISTINCT CASE WHEN hi.role = 'target' THEN hn.label END) as targets
                FROM hypergraph_edge he
                JOIN hypergraph_incidence hi ON he.id = hi.edge_id
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                LEFT JOIN article_edge_provenance aep ON he.id = aep.edge_id
                WHERE he.id IN (
                    SELECT DISTINCT edge_id FROM hypergraph_incidence WHERE node_id IN (\(placeholders))
                )
                GROUP BY he.id
                LIMIT 50
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(nodeIds))
            return rows.compactMap { row -> GraphRAGContext.ContextEdge? in
                let sourcesStr: String? = row["sources"]
                let targetsStr: String? = row["targets"]

                let sources = sourcesStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []
                let targets = targetsStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []

                // Skip edges with no meaningful connection
                guard !sources.isEmpty || !targets.isEmpty else { return nil }

                return GraphRAGContext.ContextEdge(
                    edgeId: row["id"],
                    relation: row["relation"],
                    sourceNodes: sources,
                    targetNodes: targets,
                    chunkText: row["chunk_text"]
                )
            }
        }
    }

    /// Finds chunks based on provenance links to the given nodes.
    private func findChunksFromProvenance(nodeIds: [Int64], limit: Int) throws -> [GraphRAGContext.ChunkWithArticle] {
        guard !nodeIds.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT DISTINCT ac.id as chunk_id, ac.chunk_index, ac.content,
                       0.0 as distance,
                       fi.id as article_id, fi.title as article_title
                FROM hypergraph_incidence hi
                JOIN hypergraph_edge he ON hi.edge_id = he.id
                JOIN article_edge_provenance aep ON he.id = aep.edge_id
                JOIN article_chunk ac ON aep.feed_item_id = ac.feed_item_id
                    AND aep.chunk_index = ac.chunk_index
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                WHERE hi.node_id IN (\(placeholders))
                LIMIT ?
            """

            var args = nodeIds.map { $0 as DatabaseValueConvertible }
            args.append(limit)

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            return rows.map { row in
                GraphRAGContext.ChunkWithArticle(
                    chunkId: row["chunk_id"],
                    chunkIndex: row["chunk_index"],
                    content: row["content"],
                    distance: row["distance"],
                    articleId: row["article_id"],
                    articleTitle: row["article_title"]
                )
            }
        }
    }

    // MARK: - Answer Generation

    /// Generates an answer using the LLM with the gathered context.
    @MainActor
    private func generateAnswer(question: String, context: GraphRAGContext) async throws -> String {
        let settings = try loadSettings()

        let systemPrompt = """
            You are a helpful assistant that answers questions based on a knowledge graph extracted from news articles.
            Use the provided context to answer the question accurately and concisely.
            If the context doesn't contain enough information to fully answer the question, acknowledge what you know and what's missing.
            Always cite the source articles when possible.
            """

        let contextStr = context.formatForLLM()

        let userPrompt = """
            Context from knowledge graph:

            \(contextStr)

            Question: \(question)

            Please answer the question based on the context provided above.
            """

        switch settings.provider {
        case "ollama":
            return try await generateWithOllama(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        case "openrouter":
            return try await generateWithOpenRouter(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        default:
            throw GraphRAGError.noProviderConfigured
        }
    }

    @MainActor
    private func generateWithOllama(systemPrompt: String, userPrompt: String, settings: LLMSettings) async throws -> String {
        let endpoint = settings.ollamaEndpoint ?? "http://localhost:11434"
        let model = settings.ollamaModel ?? "llama3.2:3b"

        guard let host = URL(string: endpoint) else {
            throw GraphRAGError.invalidConfiguration("Invalid Ollama endpoint")
        }

        let ollama = OllamaService(host: host, chatModel: model)
        return try await ollama.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }

    @MainActor
    private func generateWithOpenRouter(systemPrompt: String, userPrompt: String, settings: LLMSettings) async throws -> String {
        guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
            throw GraphRAGError.missingAPIKey
        }

        let model = settings.openRouterModel ?? "meta-llama/llama-4-maverick"
        let openRouter = try OpenRouterService(apiKey: apiKey, model: model)

        return try await openRouter.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            temperature: 0.7
        )
    }

    // MARK: - Graph Path Building

    /// Converts context edges to graph paths for the response.
    private func buildGraphPaths(from context: GraphRAGContext) -> [GraphRAGResponse.GraphPath] {
        context.relevantEdges.compactMap { edge in
            // Skip edges with no meaningful connections
            guard !edge.sourceNodes.isEmpty || !edge.targetNodes.isEmpty else { return nil }
            return GraphRAGResponse.GraphPath(
                id: edge.edgeId,
                relation: edge.relation,
                sourceNodes: edge.sourceNodes,
                targetNodes: edge.targetNodes
            )
        }
    }

    // MARK: - Source Building

    /// Builds source article information from the context.
    private func buildSourceArticles(from context: GraphRAGContext) throws -> [GraphRAGResponse.SourceArticle] {
        // Group chunks by article
        var articleChunks: [Int64: (title: String, chunks: [GraphRAGResponse.RelevantChunk])] = [:]

        for chunk in context.relevantChunks {
            let relevantChunk = GraphRAGResponse.RelevantChunk(
                id: chunk.chunkId,
                chunkIndex: chunk.chunkIndex,
                content: chunk.content,
                distance: chunk.distance
            )

            if var existing = articleChunks[chunk.articleId] {
                existing.chunks.append(relevantChunk)
                articleChunks[chunk.articleId] = existing
            } else {
                articleChunks[chunk.articleId] = (chunk.articleTitle, [relevantChunk])
            }
        }

        // Fetch article links
        return try database.read { db in
            var sourceArticles: [GraphRAGResponse.SourceArticle] = []

            for (articleId, info) in articleChunks {
                if let article = try FeedItem.filter(FeedItem.Columns.id == articleId).fetchOne(db) {
                    sourceArticles.append(GraphRAGResponse.SourceArticle(
                        id: articleId,
                        title: info.title,
                        link: article.link,
                        pubDate: article.pubDate,
                        relevantChunks: info.chunks
                    ))
                }
            }

            return sourceArticles.sorted { ($0.pubDate ?? .distantPast) > ($1.pubDate ?? .distantPast) }
        }
    }

    // MARK: - Configuration

    private func loadSettings() throws -> LLMSettings {
        try database.read { db in
            var settings = LLMSettings()

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

            return settings
        }
    }

    @MainActor
    private func createEmbeddingService(settings: LLMSettings) -> OllamaService {
        let embeddingEndpoint = settings.embeddingOllamaEndpoint ?? settings.ollamaEndpoint ?? "http://localhost:11434"
        let embeddingModel = settings.embeddingOllamaModel ?? "nomic-embed-text:v1.5"

        if let host = URL(string: embeddingEndpoint) {
            return OllamaService(host: host, embeddingModel: embeddingModel)
        } else {
            return OllamaService(embeddingModel: embeddingModel)
        }
    }
}

// MARK: - Errors

enum GraphRAGError: Error, LocalizedError {
    case noProviderConfigured
    case missingAPIKey
    case invalidConfiguration(String)
    case queryFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return "No LLM provider configured. Configure Ollama or OpenRouter in Settings."
        case .missingAPIKey:
            return "API key is missing for the configured provider."
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .queryFailed(let message):
            return "Query failed: \(message)"
        }
    }
}
