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

    // MARK: - Charset Decoding Tests

    /// Builds an `HTTPURLResponse` whose `textEncodingName` reflects the given charset.
    private func makeResponse(charset: String?) -> HTTPURLResponse? {
        let headers = charset.map { ["Content-Type": "text/html; charset=\($0)"] } ?? ["Content-Type": "text/html"]
        return HTTPURLResponse(
            url: URL(string: "https://example.com/")!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        )
    }

    func testDecodeHTMLUsesDeclaredCharset() {
        // 0xE9 = 'é' in ISO-8859-1; not valid as a lone byte in UTF-8.
        let data = Data([0x63, 0x61, 0x66, 0xE9])  // "café"
        let response = makeResponse(charset: "iso-8859-1")

        let decoded = ContentExtractService.decodeHTML(data: data, response: response)
        XCTAssertEqual(decoded, "café")
    }

    func testDecodeHTMLFallsBackToUTF8WhenNoCharsetDeclared() {
        let data = Data("café — résumé".utf8)
        let response = makeResponse(charset: nil)

        let decoded = ContentExtractService.decodeHTML(data: data, response: response)
        XCTAssertEqual(decoded, "café — résumé")
    }

    func testDecodeHTMLFallsBackToWindows1252ForUndeclaredLatin1() {
        // 0x92 is the Windows-1252 right single quote ('); invalid as standalone UTF-8.
        // This mirrors the paulgraham.com case: no charset header, non-UTF-8 bytes.
        let data = Data([0x49, 0x74, 0x92, 0x73])  // "It's" with curly apostrophe
        let response = makeResponse(charset: nil)

        let decoded = ContentExtractService.decodeHTML(data: data, response: response)
        XCTAssertEqual(decoded, "It\u{2019}s")
    }

    func testDecodeHTMLIgnoresUnknownCharsetAndFallsBack() {
        let data = Data("plain ascii".utf8)
        let response = makeResponse(charset: "not-a-real-charset-xyz")

        let decoded = ContentExtractService.decodeHTML(data: data, response: response)
        XCTAssertEqual(decoded, "plain ascii")
    }
}
