import XCTest
@testable import NewsCombApp

final class ClusterLabelingServiceTests: XCTestCase {

    private let service = ClusterLabelingService()

    // MARK: - parseResponse Tests

    func testParseValidResponse() throws {
        let json = """
            {"title": "Apple Unveils AI Chip Partnership", "summary": "Apple announced a new partnership with TSMC to produce custom AI chips. The deal is expected to reduce reliance on third-party silicon."}
            """

        let result = try service.parseResponse(json)
        XCTAssertEqual(result.title, "Apple Unveils AI Chip Partnership")
        XCTAssertEqual(result.summary, "Apple announced a new partnership with TSMC to produce custom AI chips. The deal is expected to reduce reliance on third-party silicon.")
    }

    func testParseResponseWithCodeFences() throws {
        let json = """
            ```json
            {"title": "EU Targets Big Tech Regulation", "summary": "The European Union proposed sweeping regulations targeting major technology companies. The rules aim to curb monopolistic practices in digital markets."}
            ```
            """

        let result = try service.parseResponse(json)
        XCTAssertEqual(result.title, "EU Targets Big Tech Regulation")
        XCTAssertTrue(result.summary.contains("European Union"))
    }

    func testParseResponseWithPlainCodeFences() throws {
        let json = """
            ```
            {"title": "Markets Rally on Fed Decision", "summary": "Stock markets surged following the Federal Reserve's decision to hold interest rates steady."}
            ```
            """

        let result = try service.parseResponse(json)
        XCTAssertEqual(result.title, "Markets Rally on Fed Decision")
    }

    func testParseInvalidJSONThrows() {
        let malformed = "This is not JSON at all"
        XCTAssertThrowsError(try service.parseResponse(malformed)) { error in
            guard let labelingError = error as? LabelingError else {
                XCTFail("Expected LabelingError, got \(type(of: error))")
                return
            }
            if case .invalidResponse(let message) = labelingError {
                XCTAssertTrue(message.contains("Malformed JSON"))
            } else {
                XCTFail("Expected .invalidResponse, got \(labelingError)")
            }
        }
    }

    func testParseMissingTitleThrows() {
        let json = """
            {"summary": "Some summary text here."}
            """
        XCTAssertThrowsError(try service.parseResponse(json)) { error in
            guard let labelingError = error as? LabelingError,
                  case .invalidResponse(let message) = labelingError else {
                XCTFail("Expected LabelingError.invalidResponse")
                return
            }
            XCTAssertTrue(message.contains("title"))
        }
    }

    func testParseMissingSummaryThrows() {
        let json = """
            {"title": "Some Title"}
            """
        XCTAssertThrowsError(try service.parseResponse(json)) { error in
            guard let labelingError = error as? LabelingError,
                  case .invalidResponse(let message) = labelingError else {
                XCTFail("Expected LabelingError.invalidResponse")
                return
            }
            XCTAssertTrue(message.contains("summary"))
        }
    }

    func testParseEmptyTitleThrows() {
        let json = """
            {"title": "", "summary": "Some summary."}
            """
        XCTAssertThrowsError(try service.parseResponse(json)) { error in
            guard let labelingError = error as? LabelingError,
                  case .invalidResponse(let message) = labelingError else {
                XCTFail("Expected LabelingError.invalidResponse")
                return
            }
            XCTAssertTrue(message.contains("title"))
        }
    }

    func testParseEmptySummaryThrows() {
        let json = """
            {"title": "Valid Title", "summary": ""}
            """
        XCTAssertThrowsError(try service.parseResponse(json)) { error in
            guard let labelingError = error as? LabelingError,
                  case .invalidResponse(let message) = labelingError else {
                XCTFail("Expected LabelingError.invalidResponse")
                return
            }
            XCTAssertTrue(message.contains("summary"))
        }
    }

    // MARK: - buildUserPrompt Tests

    private func makeExemplar(
        sentence: String,
        chunkText: String? = nil,
        articleTitle: String? = nil,
        articleDescription: String? = nil
    ) -> ClusterLabelingService.ExemplarContext {
        ClusterLabelingService.ExemplarContext(
            sentence: sentence,
            chunkText: chunkText,
            articleTitle: articleTitle,
            articleDescription: articleDescription
        )
    }

    func testBuildUserPrompt() {
        let entities = [
            RankedEntity(label: "Apple", score: 5.0),
            RankedEntity(label: "Google", score: 4.5),
            RankedEntity(label: "Microsoft", score: 3.0),
        ]
        let families = [
            RankedFamily(family: "Competition", count: 10),
            RankedFamily(family: "Partnership", count: 5),
        ]
        let exemplars = [
            makeExemplar(sentence: "Apple launches new AI product"),
            makeExemplar(sentence: "Google responds with competing service"),
        ]

        let prompt = service.buildUserPrompt(
            topEntities: entities,
            topFamilies: families,
            exemplars: exemplars
        )

        XCTAssertTrue(prompt.contains("Apple"))
        XCTAssertTrue(prompt.contains("Google"))
        XCTAssertTrue(prompt.contains("Microsoft"))
        XCTAssertTrue(prompt.contains("Competition"))
        XCTAssertTrue(prompt.contains("Partnership"))
        XCTAssertTrue(prompt.contains("1. Apple launches new AI product"))
        XCTAssertTrue(prompt.contains("2. Google responds with competing service"))
    }

    func testBuildUserPromptLimitsEntities() {
        let entities = (1...15).map { RankedEntity(label: "Entity\($0)", score: Double(16 - $0)) }
        let families = [RankedFamily(family: "Action", count: 1)]
        let exemplars = [makeExemplar(sentence: "Something happened")]

        let prompt = service.buildUserPrompt(
            topEntities: entities,
            topFamilies: families,
            exemplars: exemplars
        )

        XCTAssertTrue(prompt.contains("Entity1"))
        XCTAssertTrue(prompt.contains("Entity10"))
        XCTAssertFalse(prompt.contains("Entity11"))
    }

    func testBuildUserPromptLimitsSentences() {
        let entities = [RankedEntity(label: "Test", score: 1.0)]
        let families = [RankedFamily(family: "Action", count: 1)]
        let exemplars = (1...12).map { makeExemplar(sentence: "Event number \($0)") }

        let prompt = service.buildUserPrompt(
            topEntities: entities,
            topFamilies: families,
            exemplars: exemplars
        )

        XCTAssertTrue(prompt.contains("8. Event number 8"))
        XCTAssertFalse(prompt.contains("9. Event number 9"))
    }

    // MARK: - Chunk Text in Prompt Tests

    func testBuildUserPromptIncludesChunkText() {
        let entities = [RankedEntity(label: "Apple", score: 5.0)]
        let families = [RankedFamily(family: "launches", count: 1)]
        let exemplars = [
            makeExemplar(
                sentence: "Apple launches Vision Pro",
                chunkText: "Apple today announced the launch of Vision Pro, its first spatial computing device."
            ),
        ]

        let prompt = service.buildUserPrompt(
            topEntities: entities,
            topFamilies: families,
            exemplars: exemplars
        )

        XCTAssertTrue(prompt.contains("Source context:"))
        XCTAssertTrue(prompt.contains("Apple today announced the launch of Vision Pro"))
    }

    func testBuildUserPromptOmitsSourceContextWhenChunkTextNil() {
        let entities = [RankedEntity(label: "Apple", score: 5.0)]
        let families = [RankedFamily(family: "launches", count: 1)]
        let exemplars = [
            makeExemplar(sentence: "Apple launches Vision Pro", chunkText: nil),
        ]

        let prompt = service.buildUserPrompt(
            topEntities: entities,
            topFamilies: families,
            exemplars: exemplars
        )

        XCTAssertFalse(prompt.contains("Source context:"))
        XCTAssertTrue(prompt.contains("1. Apple launches Vision Pro"))
    }

    func testBuildUserPromptTruncatesLongChunkText() {
        let entities = [RankedEntity(label: "Apple", score: 5.0)]
        let families = [RankedFamily(family: "launches", count: 1)]
        let longText = String(repeating: "word ", count: 100) // 500 chars, exceeds 300 limit
        let exemplars = [
            makeExemplar(sentence: "Apple launches product", chunkText: longText),
        ]

        let prompt = service.buildUserPrompt(
            topEntities: entities,
            topFamilies: families,
            exemplars: exemplars
        )

        XCTAssertTrue(prompt.contains("Source context:"))
        XCTAssertTrue(prompt.contains("..."))
        // The source context should be truncated to ~300 chars + "..."
        let sourceLines = prompt.components(separatedBy: "\n")
            .filter { $0.contains("Source context:") }
        XCTAssertEqual(sourceLines.count, 1)
    }

    func testBuildUserPromptWithArticleContext() {
        let entities = [RankedEntity(label: "Apple", score: 5.0)]
        let families = [RankedFamily(family: "launches", count: 1)]
        let exemplars = [
            makeExemplar(
                sentence: "Apple launches Vision Pro",
                chunkText: "Apple announced its spatial computing device today.",
                articleTitle: "Apple Enters Spatial Computing",
                articleDescription: "The tech giant unveils its headset."
            ),
        ]

        let prompt = service.buildUserPrompt(
            topEntities: entities,
            topFamilies: families,
            exemplars: exemplars
        )

        XCTAssertTrue(prompt.contains("Source context: Apple announced"))
        XCTAssertTrue(prompt.contains("Apple Enters Spatial Computing"))
        XCTAssertTrue(prompt.contains("The tech giant unveils its headset."))
    }
}
