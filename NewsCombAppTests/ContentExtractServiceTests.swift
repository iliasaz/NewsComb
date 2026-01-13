import XCTest
@testable import NewsCombApp

final class ContentExtractServiceTests: XCTestCase {
    var service: ContentExtractService!

    override func setUp() {
        super.setUp()
        service = ContentExtractService()
    }

    override func tearDown() {
        service = nil
        super.tearDown()
    }

    // MARK: - URL Validation Tests

    func testExtractContentWithInvalidURLReturnsNil() async {
        let result = await service.extractContent(from: "not a valid url")
        XCTAssertNil(result, "Invalid URL should return nil")
    }

    func testExtractContentWithEmptyURLReturnsNil() async {
        let result = await service.extractContent(from: "")
        XCTAssertNil(result, "Empty URL should return nil")
    }

    func testExtractArticleWithInvalidURLReturnsNil() async {
        let result = await service.extractArticle(from: "invalid")
        XCTAssertNil(result, "Invalid URL should return nil for extractArticle")
    }

    // MARK: - HTML Extraction Tests

    func testExtractContentFromHTMLWithInvalidURLReturnsNil() async {
        let html = "<html><body><p>Test content</p></body></html>"
        let result = await service.extractContent(from: html, url: "not a url")
        XCTAssertNil(result, "Invalid URL should return nil even with valid HTML")
    }

    func testExtractContentFromHTMLWithEmptyURLReturnsNil() async {
        let html = "<html><body><p>Test content</p></body></html>"
        let result = await service.extractContent(from: html, url: "")
        XCTAssertNil(result, "Empty URL should return nil")
    }
}
