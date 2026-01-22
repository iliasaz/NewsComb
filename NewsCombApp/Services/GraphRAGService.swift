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
    ///   - maxNodes: Maximum number of similar nodes to retrieve per keyword
    ///   - maxChunks: Maximum number of relevant chunks to retrieve
    /// - Returns: A GraphRAGResponse containing the answer and sources
    @MainActor
    func query(_ question: String, maxNodes: Int = 5, maxChunks: Int = 5) async throws -> GraphRAGResponse {
        logger.info("GraphRAG query: \(question, privacy: .public)")

        // Step 1: Extract keywords from the question using LLM
        let keywords = try await extractKeywords(from: question)
        logger.info("Extracted keywords: \(keywords.joined(separator: ", "), privacy: .public)")

        // Step 2: Embed each keyword and find similar nodes
        var allSimilarNodes: [GraphRAGResponse.RelatedNode] = []
        var seenNodeIds: Set<Int64> = []

        for keyword in keywords {
            let keywordEmbedding = try await embedQuery(keyword)
            let nodes = try findSimilarNodes(queryEmbedding: keywordEmbedding, limit: maxNodes)

            // Deduplicate nodes across keywords
            for node in nodes where !seenNodeIds.contains(node.id) {
                seenNodeIds.insert(node.id)
                allSimilarNodes.append(node)
            }
        }

        // Sort by similarity (distance ascending)
        let similarNodes = allSimilarNodes.sorted { $0.distance < $1.distance }
        logger.info("Found \(similarNodes.count) similar nodes from \(keywords.count) keywords")

        // Step 3: Embed full question for chunk similarity search
        let questionEmbedding = try await embedQuery(question)

        // Step 4: Traverse edges from similar nodes to gather context
        let context = try gatherContext(
            fromNodes: similarNodes,
            queryEmbedding: questionEmbedding,
            maxChunks: maxChunks
        )
        logger.info("Gathered context: \(context.relevantEdges.count) edges, \(context.relevantChunks.count) chunks")

        // Step 5: Generate answer using LLM
        let answer = try await generateAnswer(question: question, context: context)
        logger.info("Answer generated successfully")

        // Step 6: Build response with sources, reasoning paths, and supporting edges
        let sourceArticles = try buildSourceArticles(from: context)
        let reasoningPaths = buildReasoningPaths(from: context)
        let graphPaths = buildGraphPaths(from: context)

        // Log reasoning path stats
        let multiHopCount = reasoningPaths.filter { $0.isMultiHop }.count
        logger.info("Reasoning paths: \(reasoningPaths.count) total, \(multiHopCount) multi-hop")

        return GraphRAGResponse(
            query: question,
            answer: answer,
            relatedNodes: similarNodes,
            reasoningPaths: reasoningPaths,
            graphPaths: graphPaths,
            sourceArticles: sourceArticles
        )
    }

    // MARK: - Keyword Extraction

    /// System prompt for keyword extraction.
    private static let keywordExtractionPrompt = """
        You are a strict keyword extractor for a knowledge graph search.

        Rules:
        - Output EXACTLY one JSON object: {"keywords": [<strings>]} with no extra text.
        - Extract the key entities, concepts, and domain-specific terms from the question.
        - Include proper nouns (people, organizations, places), technical terms, and important concepts.
        - Never include verbs, stopwords, or question words (who, what, how, etc.).
        - Lowercase all keywords unless they are acronyms or proper nouns.
        - Return 2-5 keywords maximum.
        - No explanations, just the JSON.

        Example:
        Question: "How can hydrogel mechanistically relate to PCL?"
        {"keywords": ["hydrogel", "PCL"]}

        Example:
        Question: "What companies are partnering with Google Cloud?"
        {"keywords": ["Google Cloud", "partnerships", "companies"]}
        """

    /// Extracts keywords from a question using the LLM.
    @MainActor
    private func extractKeywords(from question: String) async throws -> [String] {
        let settings = try loadSettings()

        let userPrompt = "Question: \"\(question)\""

        let response: String
        switch settings.provider {
        case "ollama":
            response = try await generateWithOllama(
                systemPrompt: Self.keywordExtractionPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        case "openrouter":
            response = try await generateWithOpenRouter(
                systemPrompt: Self.keywordExtractionPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        default:
            // Fallback: split question into words and filter stopwords
            return extractKeywordsFallback(from: question)
        }

        // Parse JSON response
        return parseKeywordsFromJSON(response) ?? extractKeywordsFallback(from: question)
    }

    /// Parses keywords from a JSON response like {"keywords": ["a", "b"]}.
    private func parseKeywordsFromJSON(_ response: String) -> [String]? {
        // Find JSON in response (handle markdown code blocks)
        let cleaned = response
            .replacing("```json", with: "")
            .replacing("```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keywords = json["keywords"] as? [String],
              !keywords.isEmpty else {
            return nil
        }

        return keywords
    }

    /// Fallback keyword extraction using simple NLP heuristics.
    private func extractKeywordsFallback(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "must", "shall", "can", "need", "dare",
            "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
            "into", "through", "during", "before", "after", "above", "below",
            "between", "under", "again", "further", "then", "once", "here",
            "there", "when", "where", "why", "how", "all", "each", "few",
            "more", "most", "other", "some", "such", "no", "nor", "not",
            "only", "own", "same", "so", "than", "too", "very", "just",
            "and", "but", "if", "or", "because", "until", "while", "what",
            "which", "who", "whom", "this", "that", "these", "those", "am",
            "about", "it", "its", "they", "their", "them", "we", "us", "our",
            "you", "your", "he", "she", "him", "her", "his", "i", "me", "my"
        ]

        let words = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }

        // Return unique keywords, max 5
        return Array(Set(words)).prefix(5).map { $0 }
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

    /// Similarity threshold for filtering results (cosine distance, lower = more similar).
    /// Cosine distance of 0.3 corresponds to ~85% similarity.
    private static let similarityThreshold: Double = 0.5

    /// Finds nodes similar to the query using sqlite-vec with cosine distance.
    /// Cosine distance = 1 - cosine_similarity, so 0 = identical, 2 = opposite.
    private func findSimilarNodes(queryEmbedding: Data, limit: Int) throws -> [GraphRAGResponse.RelatedNode] {
        try database.read { db in
            let sql = """
                SELECT hn.id, hn.node_id, hn.label, hn.node_type,
                       vec_distance_cosine(ne.embedding, ?) as distance
                FROM hypergraph_node hn
                JOIN node_embedding ne ON hn.id = ne.node_id
                WHERE vec_distance_cosine(ne.embedding, ?) < ?
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [queryEmbedding, queryEmbedding, Self.similarityThreshold, limit]
            )
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

    /// Finds chunks similar to the query using sqlite-vec with cosine distance.
    private func findSimilarChunks(queryEmbedding: Data, limit: Int) throws -> [GraphRAGContext.ChunkWithArticle] {
        try database.read { db in
            let sql = """
                SELECT ac.id as chunk_id, ac.chunk_index, ac.content,
                       vec_distance_cosine(ce.embedding, ?) as distance,
                       fi.id as article_id, fi.title as article_title
                FROM article_chunk ac
                JOIN chunk_embedding ce ON ac.id = ce.chunk_id
                JOIN feed_item fi ON ac.feed_item_id = fi.id
                WHERE vec_distance_cosine(ce.embedding, ?) < ?
                ORDER BY distance ASC
                LIMIT ?
            """

            let rows = try Row.fetchAll(
                db,
                sql: sql,
                arguments: [queryEmbedding, queryEmbedding, Self.similarityThreshold, limit]
            )
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

    private let pathService = HypergraphPathService()

    /// Gathers context from the knowledge graph based on similar nodes.
    /// Uses hypergraph BFS to find reasoning paths between nodes.
    private func gatherContext(
        fromNodes nodes: [GraphRAGResponse.RelatedNode],
        queryEmbedding: Data,
        maxChunks: Int
    ) throws -> GraphRAGContext {
        let nodeIds = nodes.map { $0.id }

        // Find reasoning paths between nodes using hypergraph BFS
        let pathReports = try pathService.findPaths(
            between: nodeIds,
            intersectionThreshold: 1,
            maxPaths: 3
        )

        // Convert path reports to reasoning paths for context
        let reasoningPaths = convertToReasoningPaths(pathReports)

        // Convert path reports to context edges with path structure
        let edges = try convertPathReportsToEdges(pathReports)

        // Also get direct edges for nodes without paths
        let directEdges = try findEdgesForNodes(nodeIds: nodeIds)

        // Merge edges, preferring path-based ones
        let allEdges = mergeEdges(pathEdges: edges, directEdges: directEdges)

        // Find relevant chunks (from chunk embeddings if available, otherwise from provenance)
        var chunks = try findSimilarChunks(queryEmbedding: queryEmbedding, limit: maxChunks)

        // If no chunks from embeddings, fall back to provenance-based chunks
        if chunks.isEmpty {
            chunks = try findChunksFromProvenance(nodeIds: nodeIds, limit: maxChunks)
        }

        return GraphRAGContext(
            relevantNodes: nodes,
            relevantEdges: allEdges,
            relevantChunks: chunks,
            reasoningPaths: reasoningPaths
        )
    }

    /// Converts hypergraph path reports to reasoning paths for the context.
    private func convertToReasoningPaths(
        _ reports: [HypergraphPathService.PathReport]
    ) -> [GraphRAGContext.ReasoningPath] {
        reports.map { report in
            // Collect all intermediate nodes from hops
            let intermediateNodes = report.hops.flatMap { $0.intersectionNodes }
            // Remove duplicates while preserving order
            let uniqueIntermediates = intermediateNodes.reduce(into: [String]()) { result, node in
                if !result.contains(node) {
                    result.append(node)
                }
            }

            return GraphRAGContext.ReasoningPath(
                sourceConcept: report.pair.0,
                targetConcept: report.pair.1,
                intermediateNodes: uniqueIntermediates,
                edgeCount: report.edgePath.count
            )
        }
    }

    /// Converts hypergraph path reports to context edges by fetching edge details from the database.
    ///
    /// - Important: The human-readable relation must be extracted from `edge_id` using
    ///   `ContextCollector.extractRelation(from:)`. The `relation` column in the database
    ///   may contain incorrectly extracted values. Edge ID format: "relation_chunkXXX_N".
    private func convertPathReportsToEdges(
        _ reports: [HypergraphPathService.PathReport]
    ) throws -> [GraphRAGContext.ContextEdge] {
        // Collect all unique edge IDs from path reports
        var edgeIds: Set<Int64> = []
        for report in reports {
            for edgeId in report.edgePath {
                edgeIds.insert(edgeId)
            }
        }

        guard !edgeIds.isEmpty else { return [] }

        // Fetch edge details from the database with proper source/target roles
        return try database.read { db in
            let placeholders = edgeIds.map { _ in "?" }.joined(separator: ", ")
            // NOTE: We fetch edge_id to extract the human-readable relation using
            // ContextCollector.extractRelation(). The relation column may have incorrect values.
            let sql = """
                SELECT he.id, he.edge_id, he.relation, aep.chunk_text,
                       GROUP_CONCAT(DISTINCT CASE WHEN hi.role = 'source' THEN hn.label END) as sources,
                       GROUP_CONCAT(DISTINCT CASE WHEN hi.role = 'target' THEN hn.label END) as targets
                FROM hypergraph_edge he
                JOIN hypergraph_incidence hi ON he.id = hi.edge_id
                JOIN hypergraph_node hn ON hi.node_id = hn.id
                LEFT JOIN article_edge_provenance aep ON he.id = aep.edge_id
                WHERE he.id IN (\(placeholders))
                GROUP BY he.id
            """

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(Array(edgeIds)))
            return rows.compactMap { row -> GraphRAGContext.ContextEdge? in
                let sourcesStr: String? = row["sources"]
                let targetsStr: String? = row["targets"]

                let sources = sourcesStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []
                let targets = targetsStr?.components(separatedBy: ",").filter { !$0.isEmpty } ?? []

                // Skip edges with no meaningful connection
                guard !sources.isEmpty || !targets.isEmpty else { return nil }

                // Extract human-readable relation from edge_id (format: "relation_chunkXXX_N")
                // Falls back to the relation column if extraction fails
                let edgeIdStr: String = row["edge_id"]
                let relation = ContextCollector.extractRelation(from: edgeIdStr) ?? row["relation"]

                return GraphRAGContext.ContextEdge(
                    edgeId: row["id"],
                    relation: relation,
                    sourceNodes: sources,
                    targetNodes: targets,
                    chunkText: row["chunk_text"]
                )
            }
        }
    }

    /// Merges path-based edges with direct edges, avoiding duplicates.
    private func mergeEdges(
        pathEdges: [GraphRAGContext.ContextEdge],
        directEdges: [GraphRAGContext.ContextEdge]
    ) -> [GraphRAGContext.ContextEdge] {
        var result = pathEdges
        let pathEdgeIds = Set(pathEdges.map { $0.edgeId })

        for edge in directEdges where !pathEdgeIds.contains(edge.edgeId) {
            result.append(edge)
        }

        return result
    }

    /// Finds edges connected to the given nodes.
    ///
    /// - Important: The human-readable relation must be extracted from `edge_id` using
    ///   `ContextCollector.extractRelation(from:)`. The `relation` column in the database
    ///   may contain incorrectly extracted values. Edge ID format: "relation_chunkXXX_N".
    private func findEdgesForNodes(nodeIds: [Int64]) throws -> [GraphRAGContext.ContextEdge] {
        guard !nodeIds.isEmpty else { return [] }

        return try database.read { db in
            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            // First find edges connected to searched nodes, then get ALL their incidences
            // NOTE: We fetch edge_id to extract the human-readable relation using
            // ContextCollector.extractRelation(). The relation column may have incorrect values.
            let sql = """
                SELECT he.id, he.edge_id, he.relation, aep.chunk_text,
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

                // Extract human-readable relation from edge_id (format: "relation_chunkXXX_N")
                // Falls back to the relation column if extraction fails
                let edgeIdStr: String = row["edge_id"]
                let relation = ContextCollector.extractRelation(from: edgeIdStr) ?? row["relation"]

                return GraphRAGContext.ContextEdge(
                    edgeId: row["id"],
                    relation: relation,
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

    /// Converts context edges to graph paths for the response, including provenance text.
    private func buildGraphPaths(from context: GraphRAGContext) -> [GraphRAGResponse.GraphPath] {
        context.relevantEdges.compactMap { edge in
            // Skip edges with no meaningful connections
            guard !edge.sourceNodes.isEmpty || !edge.targetNodes.isEmpty else { return nil }
            return GraphRAGResponse.GraphPath(
                id: edge.edgeId,
                relation: edge.relation,
                sourceNodes: edge.sourceNodes,
                targetNodes: edge.targetNodes,
                provenanceText: edge.chunkText
            )
        }
    }

    /// Builds reasoning paths from the context, filtering and deduplicating.
    private func buildReasoningPaths(from context: GraphRAGContext) -> [GraphRAGResponse.ReasoningPath] {
        // Convert context reasoning paths to response reasoning paths
        // Deduplicate by source-target pair (keep first occurrence)
        var seenPairs: Set<String> = []

        return context.reasoningPaths.compactMap { path in
            let pairKey = "\(path.sourceConcept)|\(path.targetConcept)"

            // Skip duplicates
            guard !seenPairs.contains(pairKey) else { return nil }
            seenPairs.insert(pairKey)

            return GraphRAGResponse.ReasoningPath(
                sourceConcept: path.sourceConcept,
                targetConcept: path.targetConcept,
                intermediateNodes: path.intermediateNodes,
                edgeCount: path.edgeCount
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
