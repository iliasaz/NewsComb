import XCTest
@testable import NewsCombApp

/// Integration tests for HypergraphService that require Ollama to be running.
/// These tests are skipped if Ollama is not available.
final class HypergraphIntegrationTests: XCTestCase {

    var service: HypergraphService!

    override func setUp() {
        super.setUp()
        service = HypergraphService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - Configuration Tests

    func testIsConfiguredReturnsCorrectValue() {
        // This test checks if the service correctly reads the LLM configuration
        let isConfigured = service.isConfigured()
        // The result depends on whether settings are in the database
        print("HypergraphService is configured: \(isConfigured)")
    }

    func testGetLLMProvider() {
        let provider = service.getLLMProvider()
        print("LLM Provider: \(provider ?? "nil")")
    }

    // MARK: - Statistics Tests

    func testGetStatistics() throws {
        let stats = try service.getStatistics()
        print("Hypergraph Statistics:")
        print("  - Nodes: \(stats.nodeCount)")
        print("  - Edges: \(stats.edgeCount)")
        print("  - Processed Articles: \(stats.processedArticles)")
        print("  - Embeddings: \(stats.embeddingCount)")
    }

    func testGetUnprocessedArticles() throws {
        let articles = try service.getUnprocessedArticles()
        print("Unprocessed articles with content: \(articles.count)")
        for article in articles.prefix(5) {
            print("  - [\(article.id ?? 0)] \(article.title) (content: \(article.fullContent?.count ?? 0) chars)")
        }
    }

    // MARK: - Processing Tests (Requires Ollama)

    /// This test requires Ollama to be running locally.
    /// It will process a single article and verify the hypergraph is created.
    @MainActor
    func testProcessSingleArticle() async throws {
        // Print database location
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dbPath = appSupport.appending(path: "NewsComb/newscomb.sqlite")
        NSLog("HypergraphTest: Database path = \(dbPath.path)")

        // Check configuration
        let isConfigured = service.isConfigured()
        let provider = service.getLLMProvider()
        NSLog("HypergraphTest: isConfigured=\(isConfigured), provider=\(provider ?? "nil")")

        guard isConfigured else {
            NSLog("HypergraphTest: SKIPPING - service not configured")
            throw XCTSkip("HypergraphService is not configured - set LLM provider in settings")
        }

        // Get stats before processing
        let statsBefore = try service.getStatistics()
        NSLog("HypergraphTest: Stats BEFORE - nodes=\(statsBefore.nodeCount), edges=\(statsBefore.edgeCount), processed=\(statsBefore.processedArticles)")

        // Get an unprocessed article
        let articles = try service.getUnprocessedArticles()
        NSLog("HypergraphTest: Found \(articles.count) unprocessed articles")

        guard let article = articles.first, let articleId = article.id else {
            NSLog("HypergraphTest: SKIPPING - no unprocessed articles with content")
            throw XCTSkip("No unprocessed articles with content available")
        }

        NSLog("HypergraphTest: Processing article \(articleId): \(article.title)")
        NSLog("HypergraphTest: Content length: \(article.fullContent?.count ?? 0) characters")

        // Process the article
        let startTime = Date()
        do {
            try await service.processArticle(feedItemId: articleId)
            let duration = Date().timeIntervalSince(startTime)
            NSLog("HypergraphTest: Processing completed in \(String(format: "%.2f", duration)) seconds")
        } catch {
            NSLog("HypergraphTest: ERROR processing article: \(error)")
            throw error
        }

        // Get updated statistics
        let statsAfter = try service.getStatistics()
        NSLog("HypergraphTest: Stats AFTER - nodes=\(statsAfter.nodeCount), edges=\(statsAfter.edgeCount), processed=\(statsAfter.processedArticles)")

        // Verify something was created
        XCTAssertGreaterThan(statsAfter.processedArticles, statsBefore.processedArticles, "Should have processed at least one more article")
    }
}
