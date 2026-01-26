import XCTest
@testable import NewsCombApp

final class GraphRAGTests: XCTestCase {

    // MARK: - GraphRAGResponse Tests

    func testGraphRAGResponseInitialization() {
        let date = Date(timeIntervalSince1970: 1000)
        let response = GraphRAGResponse(
            query: "What is AI?",
            answer: "AI stands for Artificial Intelligence.",
            relatedNodes: [],
            sourceArticles: [],
            generatedAt: date
        )

        XCTAssertEqual(response.query, "What is AI?")
        XCTAssertEqual(response.answer, "AI stands for Artificial Intelligence.")
        XCTAssertTrue(response.relatedNodes.isEmpty)
        XCTAssertTrue(response.sourceArticles.isEmpty)
        XCTAssertEqual(response.generatedAt, date)
    }

    func testGraphRAGResponseWithDefaults() {
        let response = GraphRAGResponse(
            query: "Test query",
            answer: "Test answer"
        )

        XCTAssertNotNil(response.id)
        XCTAssertTrue(response.relatedNodes.isEmpty)
        XCTAssertTrue(response.sourceArticles.isEmpty)
        XCTAssertNotNil(response.generatedAt)
    }

    func testGraphRAGResponseIdentifiable() {
        let response1 = GraphRAGResponse(query: "Q1", answer: "A1")
        let response2 = GraphRAGResponse(query: "Q2", answer: "A2")

        XCTAssertNotEqual(response1.id, response2.id)
    }

    // MARK: - RelatedNode Tests

    func testRelatedNodeInitialization() {
        let node = GraphRAGResponse.RelatedNode(
            id: 1,
            nodeId: "concept_ai",
            label: "Artificial Intelligence",
            nodeType: "concept",
            distance: 0.5
        )

        XCTAssertEqual(node.id, 1)
        XCTAssertEqual(node.nodeId, "concept_ai")
        XCTAssertEqual(node.label, "Artificial Intelligence")
        XCTAssertEqual(node.nodeType, "concept")
        XCTAssertEqual(node.distance, 0.5)
    }

    func testRelatedNodeSimilarityCalculation() {
        // Similarity is calculated as: max(0, min(1, 1 - distance))
        // For cosine distance: 0 = identical, 1 = orthogonal, 2 = opposite

        // Test high similarity (low distance)
        let node1 = GraphRAGResponse.RelatedNode(
            id: 1,
            nodeId: "n1",
            label: "Test",
            nodeType: nil,
            distance: 0.0
        )
        XCTAssertEqual(node1.similarity, 1.0, accuracy: 0.001)

        // Test orthogonal vectors (distance = 1.0 → similarity = 0.0)
        let node2 = GraphRAGResponse.RelatedNode(
            id: 2,
            nodeId: "n2",
            label: "Test",
            nodeType: nil,
            distance: 1.0
        )
        XCTAssertEqual(node2.similarity, 0.0, accuracy: 0.001)

        // Test opposite vectors (distance = 2.0 → similarity = 0.0, clamped)
        let node3 = GraphRAGResponse.RelatedNode(
            id: 3,
            nodeId: "n3",
            label: "Test",
            nodeType: nil,
            distance: 2.0
        )
        XCTAssertEqual(node3.similarity, 0.0, accuracy: 0.001)

        // Test clamping (distance > 2 should not go negative)
        let node4 = GraphRAGResponse.RelatedNode(
            id: 4,
            nodeId: "n4",
            label: "Test",
            nodeType: nil,
            distance: 3.0
        )
        XCTAssertGreaterThanOrEqual(node4.similarity, 0.0)

        // Test partial similarity (distance = 0.3 → similarity = 0.7)
        let node5 = GraphRAGResponse.RelatedNode(
            id: 5,
            nodeId: "n5",
            label: "Test",
            nodeType: nil,
            distance: 0.3
        )
        XCTAssertEqual(node5.similarity, 0.7, accuracy: 0.001)
    }

    func testRelatedNodeNilType() {
        let node = GraphRAGResponse.RelatedNode(
            id: 1,
            nodeId: "n1",
            label: "Test",
            nodeType: nil,
            distance: 0.5
        )

        XCTAssertNil(node.nodeType)
    }

    // MARK: - SourceArticle Tests

    func testSourceArticleInitialization() {
        let date = Date(timeIntervalSince1970: 1000)
        let article = GraphRAGResponse.SourceArticle(
            id: 1,
            title: "Test Article",
            link: "https://example.com/article",
            pubDate: date,
            relevantChunks: []
        )

        XCTAssertEqual(article.id, 1)
        XCTAssertEqual(article.title, "Test Article")
        XCTAssertEqual(article.link, "https://example.com/article")
        XCTAssertEqual(article.pubDate, date)
        XCTAssertTrue(article.relevantChunks.isEmpty)
    }

    func testSourceArticleOptionalFields() {
        let article = GraphRAGResponse.SourceArticle(
            id: 1,
            title: "Test",
            link: nil,
            pubDate: nil,
            relevantChunks: []
        )

        XCTAssertNil(article.link)
        XCTAssertNil(article.pubDate)
    }

    // MARK: - RelevantChunk Tests

    func testRelevantChunkInitialization() {
        let chunk = GraphRAGResponse.RelevantChunk(
            id: 1,
            chunkIndex: 0,
            content: "This is the chunk content.",
            distance: 0.3
        )

        XCTAssertEqual(chunk.id, 1)
        XCTAssertEqual(chunk.chunkIndex, 0)
        XCTAssertEqual(chunk.content, "This is the chunk content.")
        XCTAssertEqual(chunk.distance, 0.3)
    }

    func testRelevantChunkSimilarity() {
        let chunk = GraphRAGResponse.RelevantChunk(
            id: 1,
            chunkIndex: 0,
            content: "Test",
            distance: 0.4
        )

        // similarity = max(0, min(1, 1 - distance)) = 1 - 0.4 = 0.6
        XCTAssertEqual(chunk.similarity, 0.6, accuracy: 0.001)
    }

    // MARK: - GraphRAGContext Tests

    func testGraphRAGContextInitialization() {
        let node = GraphRAGResponse.RelatedNode(
            id: 1,
            nodeId: "n1",
            label: "AI",
            nodeType: "concept",
            distance: 0.5
        )
        let edge = GraphRAGContext.ContextEdge(
            edgeId: 1,
            relation: "is_a",
            sourceNodes: ["AI"],
            targetNodes: ["Technology"],
            chunkText: "AI is a technology"
        )
        let chunk = GraphRAGContext.ChunkWithArticle(
            chunkId: 1,
            chunkIndex: 0,
            content: "AI content",
            distance: 0.3,
            articleId: 100,
            articleTitle: "AI Article"
        )

        let context = GraphRAGContext(
            relevantNodes: [node],
            relevantEdges: [edge],
            relevantChunks: [chunk]
        )

        XCTAssertEqual(context.relevantNodes.count, 1)
        XCTAssertEqual(context.relevantEdges.count, 1)
        XCTAssertEqual(context.relevantChunks.count, 1)
    }

    func testContextEdgeInitialization() {
        let edge = GraphRAGContext.ContextEdge(
            edgeId: 42,
            relation: "related_to",
            sourceNodes: ["Source1", "Source2"],
            targetNodes: ["Target1"],
            chunkText: "Source is related to target"
        )

        XCTAssertEqual(edge.edgeId, 42)
        XCTAssertEqual(edge.relation, "related_to")
        XCTAssertEqual(edge.sourceNodes, ["Source1", "Source2"])
        XCTAssertEqual(edge.targetNodes, ["Target1"])
        XCTAssertEqual(edge.chunkText, "Source is related to target")
    }

    func testContextEdgeNilChunkText() {
        let edge = GraphRAGContext.ContextEdge(
            edgeId: 1,
            relation: "test",
            sourceNodes: [],
            targetNodes: [],
            chunkText: nil
        )

        XCTAssertNil(edge.chunkText)
    }

    func testChunkWithArticleInitialization() {
        let chunk = GraphRAGContext.ChunkWithArticle(
            chunkId: 1,
            chunkIndex: 2,
            content: "Chunk content here",
            distance: 0.25,
            articleId: 100,
            articleTitle: "Test Article"
        )

        XCTAssertEqual(chunk.chunkId, 1)
        XCTAssertEqual(chunk.chunkIndex, 2)
        XCTAssertEqual(chunk.content, "Chunk content here")
        XCTAssertEqual(chunk.distance, 0.25)
        XCTAssertEqual(chunk.articleId, 100)
        XCTAssertEqual(chunk.articleTitle, "Test Article")
    }

    // MARK: - GraphRAGContext FormatForLLM Tests

    func testFormatForLLMWithNodes() {
        let node = GraphRAGResponse.RelatedNode(
            id: 1,
            nodeId: "n1",
            label: "AI",
            nodeType: "concept",
            distance: 0.5
        )

        let context = GraphRAGContext(
            relevantNodes: [node],
            relevantEdges: [],
            relevantChunks: []
        )

        let formatted = context.formatForLLM()

        XCTAssertTrue(formatted.contains("Relevant Concepts"))
        XCTAssertTrue(formatted.contains("AI"))
        XCTAssertTrue(formatted.contains("(concept)"))
    }

    func testFormatForLLMWithEdges() {
        let edge = GraphRAGContext.ContextEdge(
            edgeId: 1,
            relation: "is_a",
            sourceNodes: ["AI"],
            targetNodes: ["Technology"],
            chunkText: nil
        )

        let context = GraphRAGContext(
            relevantNodes: [],
            relevantEdges: [edge],
            relevantChunks: []
        )

        let formatted = context.formatForLLM()

        XCTAssertTrue(formatted.contains("Relationships"))
        XCTAssertTrue(formatted.contains("AI"))
        // formatEdge() converts underscores to spaces: "is_a" → "is a"
        XCTAssertTrue(formatted.contains("is a"))
        XCTAssertTrue(formatted.contains("Technology"))
    }

    func testFormatForLLMWithChunks() {
        let chunk = GraphRAGContext.ChunkWithArticle(
            chunkId: 1,
            chunkIndex: 0,
            content: "This is important content about AI.",
            distance: 0.3,
            articleId: 100,
            articleTitle: "AI Article"
        )

        let context = GraphRAGContext(
            relevantNodes: [],
            relevantEdges: [],
            relevantChunks: [chunk]
        )

        let formatted = context.formatForLLM()

        XCTAssertTrue(formatted.contains("Source Content"))
        XCTAssertTrue(formatted.contains("AI Article"))
        XCTAssertTrue(formatted.contains("important content about AI"))
    }

    func testFormatForLLMEmpty() {
        let context = GraphRAGContext(
            relevantNodes: [],
            relevantEdges: [],
            relevantChunks: []
        )

        let formatted = context.formatForLLM()

        XCTAssertTrue(formatted.isEmpty)
    }

    // MARK: - GraphRAGError Tests

    func testGraphRAGErrorDescriptions() {
        XCTAssertEqual(
            GraphRAGError.noProviderConfigured.errorDescription,
            "No LLM provider configured. Configure Ollama or OpenRouter in Settings."
        )
        XCTAssertEqual(
            GraphRAGError.missingAPIKey.errorDescription,
            "API key is missing for the configured provider."
        )
        XCTAssertEqual(
            GraphRAGError.invalidConfiguration("test").errorDescription,
            "Invalid configuration: test"
        )
        XCTAssertEqual(
            GraphRAGError.queryFailed("test error").errorDescription,
            "Query failed: test error"
        )
    }

    // MARK: - MergeSuggestion Tests

    func testMergeSuggestionInitialization() {
        let suggestion = MergeSuggestion(
            node1Id: 1,
            node1Label: "Apple Inc",
            node1Type: "company",
            node2Id: 2,
            node2Label: "Apple",
            node2Type: "company",
            similarity: 0.95
        )

        XCTAssertEqual(suggestion.node1Id, 1)
        XCTAssertEqual(suggestion.node1Label, "Apple Inc")
        XCTAssertEqual(suggestion.node1Type, "company")
        XCTAssertEqual(suggestion.node2Id, 2)
        XCTAssertEqual(suggestion.node2Label, "Apple")
        XCTAssertEqual(suggestion.node2Type, "company")
        XCTAssertEqual(suggestion.similarity, 0.95)
    }

    func testMergeSuggestionIdentifiable() {
        let suggestion = MergeSuggestion(
            node1Id: 10,
            node1Label: "A",
            node1Type: nil,
            node2Id: 20,
            node2Label: "B",
            node2Type: nil,
            similarity: 0.9
        )

        XCTAssertEqual(suggestion.id, "10-20")
    }

    func testMergeSuggestionNilTypes() {
        let suggestion = MergeSuggestion(
            node1Id: 1,
            node1Label: "A",
            node1Type: nil,
            node2Id: 2,
            node2Label: "B",
            node2Type: nil,
            similarity: 0.85
        )

        XCTAssertNil(suggestion.node1Type)
        XCTAssertNil(suggestion.node2Type)
    }

    // MARK: - GraphRAGViewModel Sample Queries Tests

    func testSampleQueriesNotEmpty() {
        XCTAssertFalse(GraphRAGViewModel.sampleQueries.isEmpty)
    }

    func testSampleQueriesAreQuestions() {
        for query in GraphRAGViewModel.sampleQueries {
            // Sample queries should end with a question mark or be meaningful prompts
            let isQuestion = query.hasSuffix("?")
            let isPrompt = query.contains("What") || query.contains("How") || query.contains("Summarize") || query.contains("Generate")
            XCTAssertTrue(isQuestion || isPrompt, "Sample query should be a question or prompt: \(query)")
        }
    }
}
