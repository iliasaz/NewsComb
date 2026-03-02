import XCTest
@testable import NewsCombApp

final class OPMLImportServiceTests: XCTestCase {
    private let service = OPMLImportService()

    // MARK: - Valid OPML Parsing

    func testParseValidOPMLWithNestedOutlines() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
            <head><title>Test Feeds</title></head>
            <body>
                <outline text="Blogs" title="Blogs">
                    <outline type="rss" text="Example Blog" title="Example Blog"
                             xmlUrl="https://example.com/feed.xml"
                             htmlUrl="https://example.com" />
                    <outline type="rss" text="Another Blog" title="Another Blog"
                             xmlUrl="https://another.com/rss"
                             htmlUrl="https://another.com" />
                </outline>
            </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let feeds = try service.parseFeeds(from: data)

        XCTAssertEqual(feeds.count, 2)
        XCTAssertEqual(feeds[0].xmlUrl, "https://example.com/feed.xml")
        XCTAssertEqual(feeds[0].title, "Example Blog")
        XCTAssertEqual(feeds[0].htmlUrl, "https://example.com")
        XCTAssertEqual(feeds[1].xmlUrl, "https://another.com/rss")
    }

    func testParseFlatOPML() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
            <head><title>Flat Feeds</title></head>
            <body>
                <outline type="rss" text="Feed One" title="Feed One"
                         xmlUrl="https://one.com/feed" htmlUrl="https://one.com" />
                <outline type="rss" text="Feed Two" title="Feed Two"
                         xmlUrl="https://two.com/feed" htmlUrl="https://two.com" />
            </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let feeds = try service.parseFeeds(from: data)

        XCTAssertEqual(feeds.count, 2)
        XCTAssertEqual(feeds[0].xmlUrl, "https://one.com/feed")
        XCTAssertEqual(feeds[1].xmlUrl, "https://two.com/feed")
    }

    func testParseDeeplyNestedOPML() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
            <head><title>Deep Nesting</title></head>
            <body>
                <outline text="Tech">
                    <outline text="Programming">
                        <outline type="rss" text="Deep Feed" title="Deep Feed"
                                 xmlUrl="https://deep.com/feed" htmlUrl="https://deep.com" />
                    </outline>
                </outline>
            </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let feeds = try service.parseFeeds(from: data)

        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds[0].xmlUrl, "https://deep.com/feed")
        XCTAssertEqual(feeds[0].title, "Deep Feed")
    }

    // MARK: - Empty & Edge Cases

    func testParseEmptyOPML() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
            <head><title>Empty</title></head>
            <body></body>
        </opml>
        """
        let data = Data(opml.utf8)
        let feeds = try service.parseFeeds(from: data)

        XCTAssertTrue(feeds.isEmpty)
    }

    func testCategoryOutlinesWithoutXmlUrlAreSkipped() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
            <head><title>Mixed</title></head>
            <body>
                <outline text="Category Only" title="Category Only" />
                <outline type="rss" text="Real Feed" title="Real Feed"
                         xmlUrl="https://real.com/feed" htmlUrl="https://real.com" />
            </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let feeds = try service.parseFeeds(from: data)

        XCTAssertEqual(feeds.count, 1)
        XCTAssertEqual(feeds[0].xmlUrl, "https://real.com/feed")
    }

    // MARK: - Deduplication

    func testDuplicateURLsAreDeduped() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
            <head><title>Dupes</title></head>
            <body>
                <outline type="rss" text="Feed A" title="Feed A"
                         xmlUrl="https://example.com/feed" htmlUrl="https://example.com" />
                <outline type="rss" text="Feed B" title="Feed B"
                         xmlUrl="https://EXAMPLE.COM/feed" htmlUrl="https://example.com" />
            </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let feeds = try service.parseFeeds(from: data)

        XCTAssertEqual(feeds.count, 1, "Duplicate URLs (case-insensitive) should be deduped")
        XCTAssertEqual(feeds[0].title, "Feed A", "First occurrence should be kept")
    }

    // MARK: - Invalid Input

    func testInvalidXMLThrowsError() {
        let invalidData = Data("This is not XML at all".utf8)

        XCTAssertThrowsError(try service.parseFeeds(from: invalidData))
    }

    // MARK: - Title Handling

    func testEmptyTitleBecomesNil() throws {
        let opml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <opml version="2.0">
            <head><title>Test</title></head>
            <body>
                <outline type="rss" text="" title=""
                         xmlUrl="https://notitle.com/feed" htmlUrl="https://notitle.com" />
            </body>
        </opml>
        """
        let data = Data(opml.utf8)
        let feeds = try service.parseFeeds(from: data)

        XCTAssertEqual(feeds.count, 1)
        XCTAssertNil(feeds[0].title, "Empty title string should become nil")
    }

    // MARK: - Import Result

    func testOPMLImportResultEquality() {
        let result1 = OPMLImportResult(added: 5, skipped: 2, total: 7)
        let result2 = OPMLImportResult(added: 5, skipped: 2, total: 7)
        let result3 = OPMLImportResult(added: 3, skipped: 4, total: 7)

        XCTAssertEqual(result1, result2)
        XCTAssertNotEqual(result1, result3)
    }
}
