import XCTest
@testable import NewsCombApp

final class FTSSearchTests: XCTestCase {

    // MARK: - GraphSearchResults Tests

    func testAllMatchedNodeIdsIncludesDirectAndContentDerived() {
        let nodeMatches = [
            FTSNodeMatch(id: 1, label: "Apple", nodeType: "Company", snippet: "<b>Apple</b>", rank: -1.0),
            FTSNodeMatch(id: 2, label: "Google", nodeType: "Company", snippet: "<b>Google</b>", rank: -0.9)
        ]

        let contentDerived = [
            FTSNodeMatch(id: 3, label: "Microsoft", nodeType: "Company", snippet: "...about <b>Apple</b> and Microsoft...", rank: -0.8, articleTitle: "Tech News"),
            FTSNodeMatch(id: 4, label: "Tim Cook", nodeType: "Person", snippet: "...about <b>Apple</b>...", rank: -0.7, articleTitle: "More News")
        ]

        let results = GraphSearchResults(query: "Apple", nodeMatches: nodeMatches, contentDerivedNodes: contentDerived)
        let allIds = results.allMatchedNodeIds

        // Direct node matches
        XCTAssertTrue(allIds.contains(1))
        XCTAssertTrue(allIds.contains(2))

        // Content-derived nodes
        XCTAssertTrue(allIds.contains(3))
        XCTAssertTrue(allIds.contains(4))

        XCTAssertEqual(allIds.count, 4)
    }

    func testEmptySearchResults() {
        let results = GraphSearchResults(query: "nonexistent", nodeMatches: [], contentDerivedNodes: [])

        XCTAssertTrue(results.isEmpty)
        XCTAssertEqual(results.totalCount, 0)
        XCTAssertTrue(results.allMatchedNodeIds.isEmpty)
    }

    func testNonEmptySearchResults() {
        let nodeMatches = [
            FTSNodeMatch(id: 1, label: "Test", nodeType: nil, snippet: "<b>Test</b>", rank: -1.0)
        ]
        let contentDerived = [
            FTSNodeMatch(id: 2, label: "Related", nodeType: nil, snippet: "...<b>Test</b>...", rank: -0.5, articleTitle: "Article")
        ]

        let results = GraphSearchResults(query: "test", nodeMatches: nodeMatches, contentDerivedNodes: contentDerived)

        XCTAssertFalse(results.isEmpty)
        XCTAssertEqual(results.totalCount, 2)
    }

    func testContentDerivedResultsCountSeparately() {
        let nodeMatches = [
            FTSNodeMatch(id: 1, label: "A", nodeType: nil, snippet: "", rank: -1.0)
        ]
        let contentDerived = [
            FTSNodeMatch(id: 2, label: "B", nodeType: nil, snippet: "", rank: -0.5, articleTitle: "Article 1"),
            FTSNodeMatch(id: 3, label: "C", nodeType: nil, snippet: "", rank: -0.4, articleTitle: "Article 2")
        ]

        let results = GraphSearchResults(query: "x", nodeMatches: nodeMatches, contentDerivedNodes: contentDerived)
        XCTAssertEqual(results.totalCount, 3)
        XCTAssertEqual(results.allMatchedNodeIds.count, 3)
    }

    // MARK: - FTSNodeMatch Tests

    func testFTSNodeMatchIdentity() {
        let match = FTSNodeMatch(id: 42, label: "Test Node", nodeType: "concept", snippet: "<b>Test</b>", rank: -1.0)
        XCTAssertEqual(match.id, 42)
    }

    func testDirectMatchIsNotContentDerived() {
        let match = FTSNodeMatch(id: 1, label: "Test", nodeType: nil, snippet: "", rank: -1.0)
        XCTAssertFalse(match.isContentDerived)
        XCTAssertNil(match.articleTitle)
    }

    func testIndirectMatchIsContentDerived() {
        let match = FTSNodeMatch(id: 1, label: "Test", nodeType: nil, snippet: "", rank: -1.0, articleTitle: "Some Article")
        XCTAssertTrue(match.isContentDerived)
        XCTAssertEqual(match.articleTitle, "Some Article")
    }

    // MARK: - FTS Query Sanitization Tests

    func testSanitizeFTSQuerySingleWord() {
        let sanitized = GraphDataService.sanitizeFTSQuery("apple")
        XCTAssertEqual(sanitized, "\"apple*\"")
    }

    func testSanitizeFTSQueryMultipleWords() {
        let sanitized = GraphDataService.sanitizeFTSQuery("apple revenue growth")
        XCTAssertEqual(sanitized, "\"apple\" \"revenue\" \"growth*\"")
    }

    func testSanitizeFTSQueryTrimsWhitespace() {
        let sanitized = GraphDataService.sanitizeFTSQuery("  hello  world  ")
        XCTAssertEqual(sanitized, "\"hello\" \"world*\"")
    }

    func testSanitizeFTSQueryEmpty() {
        XCTAssertEqual(GraphDataService.sanitizeFTSQuery(""), "")
        XCTAssertEqual(GraphDataService.sanitizeFTSQuery("   "), "")
    }

    func testSanitizeFTSQueryEscapesQuotes() {
        let sanitized = GraphDataService.sanitizeFTSQuery("say \"hello\"")
        // Double quotes inside should be escaped as ""
        XCTAssertTrue(sanitized.contains("\"\""))
    }
}
