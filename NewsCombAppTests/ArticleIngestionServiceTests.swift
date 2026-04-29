import XCTest
import GRDB
@testable import NewsCombApp

/// Tests for `ArticleIngestionService` — the MCP-driven manual feed and
/// article ingestion path. Uses an in-memory `DatabaseQueue` and a stub
/// extractor so no network is required.
final class ArticleIngestionServiceTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUpWithError() throws {
        try super.setUpWithError()
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: config)
        try dbQueue.write { db in
            try Self.createSchema(db)
        }
    }

    override func tearDown() {
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - createManualFeed

    func testCreateManualFeedInsertsRowWithSyntheticURL() throws {
        let service = makeService()
        let source = try service.createManualFeed(title: "  My Notes  ")

        XCTAssertNotNil(source.id)
        XCTAssertEqual(source.title, "My Notes", "Title should be trimmed")
        XCTAssertTrue(source.url.hasPrefix("manual:feed:"), "URL should use synthetic manual scheme, got '\(source.url)'")

        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source")!
            XCTAssertEqual(count, 1)
        }
    }

    func testCreateManualFeedRejectsEmptyTitle() {
        let service = makeService()
        XCTAssertThrowsError(try service.createManualFeed(title: "   ")) { error in
            guard case ArticleIngestionService.IngestionError.emptyTitle = error else {
                return XCTFail("Expected .emptyTitle, got \(error)")
            }
        }
    }

    func testCreateManualFeedGeneratesUniqueURLs() throws {
        let service = makeService()
        let first = try service.createManualFeed(title: "Feed A")
        let second = try service.createManualFeed(title: "Feed B")
        XCTAssertNotEqual(first.url, second.url, "Each manual feed must get a fresh synthetic URL")
    }

    func testIsManualSourceURLDetectsScheme() {
        XCTAssertTrue(ArticleIngestionService.isManualSourceURL("manual:feed:abc"))
        XCTAssertTrue(ArticleIngestionService.isManualSourceURL("manual:item:abc"))
        XCTAssertFalse(ArticleIngestionService.isManualSourceURL("https://example.com/feed.xml"))
        XCTAssertFalse(ArticleIngestionService.isManualSourceURL(""))
    }

    // MARK: - ingestArticle

    func testIngestArticleStoresFullContent() throws {
        let service = makeService()
        let source = try service.createManualFeed(title: "Notes")

        let body = String(repeating: "Lorem ipsum dolor sit amet. ", count: 8)  // > 100 chars
        let article = try service.ingestArticle(
            sourceId: source.id!,
            title: "Hello",
            body: body,
            link: "https://example.com/post",
            author: "Alice",
            pubDate: Date(timeIntervalSince1970: 1_700_000_000)
        )

        XCTAssertNotNil(article.id)
        XCTAssertEqual(article.title, "Hello")
        XCTAssertEqual(article.link, "https://example.com/post")
        XCTAssertEqual(article.author, "Alice")
        XCTAssertEqual(article.fullContent, body.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertEqual(article.guid, "https://example.com/post", "guid should default to link")
        XCTAssertEqual(article.pubDate?.timeIntervalSince1970 ?? 0, 1_700_000_000, accuracy: 0.001)
    }

    func testIngestArticleGeneratesSyntheticLinkWhenAbsent() throws {
        let service = makeService()
        let source = try service.createManualFeed(title: "Notes")

        let body = String(repeating: "abcdefghij", count: 12)  // 120 chars
        let article = try service.ingestArticle(
            sourceId: source.id!,
            title: "T",
            body: body
        )

        XCTAssertTrue(article.link.hasPrefix("manual:item:"), "Synthetic link should be generated, got '\(article.link)'")
        XCTAssertEqual(article.guid, article.link, "guid should equal the synthetic link")
    }

    func testIngestArticleUpsertsOnConflictingGuid() throws {
        let service = makeService()
        let source = try service.createManualFeed(title: "Notes")
        let body1 = String(repeating: "first body content. ", count: 10)  // ~200 chars
        let body2 = String(repeating: "second body content. ", count: 10)

        let first = try service.ingestArticle(
            sourceId: source.id!,
            title: "v1",
            body: body1,
            link: "https://example.com/x",
            guid: "stable-guid"
        )
        let second = try service.ingestArticle(
            sourceId: source.id!,
            title: "v2",
            body: body2,
            link: "https://example.com/x-renamed",
            guid: "stable-guid"
        )

        XCTAssertEqual(first.id, second.id, "Same guid should update the same row")
        XCTAssertEqual(second.title, "v2")
        XCTAssertEqual(second.link, "https://example.com/x-renamed")
        XCTAssertEqual(second.fullContent, body2.trimmingCharacters(in: .whitespacesAndNewlines))

        try dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item")!
            XCTAssertEqual(count, 1, "Upsert must not create a duplicate row")
        }
    }

    func testIngestArticleRejectsTooShortBody() throws {
        let service = makeService()
        let source = try service.createManualFeed(title: "Notes")

        XCTAssertThrowsError(try service.ingestArticle(
            sourceId: source.id!,
            title: "T",
            body: "too short"
        )) { error in
            guard case ArticleIngestionService.IngestionError.bodyTooShort = error else {
                return XCTFail("Expected .bodyTooShort, got \(error)")
            }
        }
    }

    func testIngestArticleRejectsEmptyTitle() throws {
        let service = makeService()
        let source = try service.createManualFeed(title: "Notes")
        let body = String(repeating: "x", count: 200)

        XCTAssertThrowsError(try service.ingestArticle(
            sourceId: source.id!,
            title: "   ",
            body: body
        )) { error in
            guard case ArticleIngestionService.IngestionError.emptyTitle = error else {
                return XCTFail("Expected .emptyTitle, got \(error)")
            }
        }
    }

    func testIngestArticleRejectsUnknownSource() {
        let service = makeService()
        let body = String(repeating: "x", count: 200)

        XCTAssertThrowsError(try service.ingestArticle(
            sourceId: 99_999,
            title: "T",
            body: body
        )) { error in
            guard case ArticleIngestionService.IngestionError.sourceNotFound = error else {
                return XCTFail("Expected .sourceNotFound, got \(error)")
            }
        }
    }

    func testIngestArticleRejectsNonManualSource() throws {
        // Insert a real RSS source by hand
        let realId = try dbQueue.write { db -> Int64 in
            try db.execute(sql: "INSERT INTO rss_source (url, title) VALUES (?, ?)",
                           arguments: ["https://example.com/feed.xml", "Real Feed"])
            return db.lastInsertedRowID
        }

        let service = makeService()
        let body = String(repeating: "x", count: 200)

        XCTAssertThrowsError(try service.ingestArticle(
            sourceId: realId,
            title: "T",
            body: body
        )) { error in
            guard case ArticleIngestionService.IngestionError.sourceIsNotManual = error else {
                return XCTFail("Expected .sourceIsNotManual, got \(error)")
            }
        }
    }

    // MARK: - refreshArticle

    func testRefreshArticleUpdatesContentAndLinkOnRedirect() async throws {
        let stubbed = ExtractionResult(
            content: String(repeating: "fresh content. ", count: 20),  // ~300 chars
            finalURL: "https://example.com/redirected"
        )
        let service = makeService(extract: { _ in stubbed })

        let source = try service.createManualFeed(title: "Notes")
        let originalBody = String(repeating: "old content. ", count: 10)
        let item = try service.ingestArticle(
            sourceId: source.id!,
            title: "T",
            body: originalBody,
            link: "https://example.com/original"
        )

        let outcome = try await service.refreshArticle(feedItemId: item.id!)

        XCTAssertEqual(outcome.feedItemId, item.id!)
        XCTAssertEqual(outcome.previousLink, "https://example.com/original")
        XCTAssertEqual(outcome.newLink, "https://example.com/redirected")
        XCTAssertTrue(outcome.linkChanged)
        XCTAssertEqual(outcome.previousContentLength, originalBody.trimmingCharacters(in: .whitespacesAndNewlines).count)
        XCTAssertGreaterThan(outcome.newContentLength, 0)

        try await dbQueue.read { db in
            let row = try FeedItem.filter(FeedItem.Columns.id == item.id!).fetchOne(db)
            XCTAssertEqual(row?.link, "https://example.com/redirected")
            // The service runs strippingHTMLTags() over extracted content, which
            // also trims surrounding whitespace and collapses runs.
            XCTAssertEqual(row?.fullContent, stubbed.content?.strippingHTMLTags())
        }
    }

    func testRefreshArticleWithoutRedirectKeepsLink() async throws {
        let stubbed = ExtractionResult(
            content: String(repeating: "abc", count: 50),
            finalURL: nil
        )
        let service = makeService(extract: { _ in stubbed })
        let source = try service.createManualFeed(title: "Notes")
        let item = try service.ingestArticle(
            sourceId: source.id!,
            title: "T",
            body: String(repeating: "x", count: 200),
            link: "https://example.com/keep"
        )

        let outcome = try await service.refreshArticle(feedItemId: item.id!)
        XCTAssertEqual(outcome.newLink, "https://example.com/keep")
        XCTAssertFalse(outcome.linkChanged)
    }

    func testRefreshArticleThrowsOnUnknownId() async {
        let service = makeService(extract: { _ in ExtractionResult(content: "ignored", finalURL: nil) })
        do {
            _ = try await service.refreshArticle(feedItemId: 12_345)
            XCTFail("Expected .feedItemNotFound to be thrown")
        } catch ArticleIngestionService.IngestionError.feedItemNotFound {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshArticleRejectsManualLinkScheme() async throws {
        let service = makeService(extract: { _ in
            // The extractor must not be invoked; if it is, return content that would otherwise succeed.
            ExtractionResult(content: String(repeating: "x", count: 200), finalURL: nil)
        })
        let source = try service.createManualFeed(title: "Notes")
        let item = try service.ingestArticle(
            sourceId: source.id!,
            title: "T",
            body: String(repeating: "x", count: 200)
            // No link → synthetic manual:item:<uuid>
        )

        do {
            _ = try await service.refreshArticle(feedItemId: item.id!)
            XCTFail("Expected .nonHTTPLink for synthetic manual link")
        } catch ArticleIngestionService.IngestionError.nonHTTPLink {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshArticleThrowsWhenExtractionReturnsNil() async throws {
        let service = makeService(extract: { _ in ExtractionResult(content: nil, finalURL: nil) })
        let source = try service.createManualFeed(title: "Notes")
        let item = try service.ingestArticle(
            sourceId: source.id!,
            title: "T",
            body: String(repeating: "x", count: 200),
            link: "https://example.com/x"
        )

        do {
            _ = try await service.refreshArticle(feedItemId: item.id!)
            XCTFail("Expected .extractionFailed")
        } catch ArticleIngestionService.IngestionError.extractionFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRefreshArticleThrowsWhenExtractedContentTooShort() async throws {
        let service = makeService(extract: { _ in ExtractionResult(content: "tiny", finalURL: nil) })
        let source = try service.createManualFeed(title: "Notes")
        let item = try service.ingestArticle(
            sourceId: source.id!,
            title: "T",
            body: String(repeating: "x", count: 200),
            link: "https://example.com/x"
        )

        do {
            _ = try await service.refreshArticle(feedItemId: item.id!)
            XCTFail("Expected .extractionFailed for sub-minimum extracted content")
        } catch ArticleIngestionService.IngestionError.extractionFailed {
            // expected
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    // MARK: - Helpers

    private func makeService(
        extract: @escaping ArticleIngestionService.Extractor = { _ in
            ExtractionResult(content: nil, finalURL: nil)
        }
    ) -> ArticleIngestionService {
        ArticleIngestionService(dbQueue: dbQueue, extract: extract)
    }

    private static func createSchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE rss_source (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                title TEXT,
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE feed_item (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id INTEGER NOT NULL REFERENCES rss_source(id) ON DELETE CASCADE,
                guid TEXT NOT NULL,
                title TEXT NOT NULL,
                link TEXT NOT NULL,
                pub_date REAL,
                rss_description TEXT,
                full_content TEXT,
                author TEXT,
                fetched_at REAL NOT NULL DEFAULT (unixepoch()),
                UNIQUE(source_id, guid)
            );
        """)
    }
}
