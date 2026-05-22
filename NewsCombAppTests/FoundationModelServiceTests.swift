import XCTest
import HyperGraphReasoning
@testable import NewsCombApp

final class FoundationModelServiceTests: XCTestCase {

    // MARK: - Availability Tests

    func testAvailabilityCheck_returnsUnavailableOnMacOS() {
        // On macOS CI (without Apple Intelligence), the check should return unavailable.
        let availability = FoundationModelAvailability.check()
        switch availability {
        case .available:
            // If running on a supported Mac with Apple Intelligence, this is fine
            break
        case .unavailable(let reason):
            XCTAssertFalse(reason.isEmpty, "Unavailable reason should not be empty")
        }
    }

    func testAvailabilityStatusDescription_available() {
        let availability = FoundationModelAvailability.available
        XCTAssertEqual(availability.statusDescription, "Available")
        XCTAssertTrue(availability.isAvailable)
    }

    func testAvailabilityStatusDescription_unavailable() {
        let availability = FoundationModelAvailability.unavailable(reason: "Test reason")
        XCTAssertEqual(availability.statusDescription, "Test reason")
        XCTAssertFalse(availability.isAvailable)
    }

    // MARK: - Conversion Logic Tests

    func testConvertGenerableEventsToHypergraphJSON_empty() {
        let result = convertGenerableEventsToHypergraphJSON(events: [])
        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(result.count, 0)
    }

    func testConvertGenerableEventsToHypergraphJSON_singleEvent() {
        let events: [(source: [String], relation: String, target: [String])] = [
            (source: ["Apple"], relation: "announces", target: ["Vision Pro"])
        ]

        let result = convertGenerableEventsToHypergraphJSON(events: events)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.events[0].source, ["Apple"])
        XCTAssertEqual(result.events[0].relation, "announces")
        XCTAssertEqual(result.events[0].target, ["Vision Pro"])
    }

    func testConvertGenerableEventsToHypergraphJSON_multipleEvents() {
        let events: [(source: [String], relation: String, target: [String])] = [
            (source: ["Apple"], relation: "announces", target: ["Vision Pro"]),
            (source: ["Google", "DeepMind"], relation: "releases", target: ["Gemini"]),
            (source: ["Tesla"], relation: "reduces price of", target: ["Model Y", "Model 3"])
        ]

        let result = convertGenerableEventsToHypergraphJSON(events: events)

        XCTAssertEqual(result.count, 3)

        // Check multi-source event
        XCTAssertEqual(result.events[1].source, ["Google", "DeepMind"])
        XCTAssertEqual(result.events[1].target, ["Gemini"])

        // Check multi-target event
        XCTAssertEqual(result.events[2].target, ["Model Y", "Model 3"])
    }

    func testConvertGenerableEventsToHypergraphJSON_allNodesExtracted() {
        let events: [(source: [String], relation: String, target: [String])] = [
            (source: ["Microsoft", "Oracle"], relation: "partners with", target: ["OpenAI"])
        ]

        let result = convertGenerableEventsToHypergraphJSON(events: events)

        let allNodes = result.allNodes
        XCTAssertEqual(allNodes.count, 3)
        XCTAssertTrue(allNodes.contains("Microsoft"))
        XCTAssertTrue(allNodes.contains("Oracle"))
        XCTAssertTrue(allNodes.contains("OpenAI"))
    }

    func testConvertGenerableEventsToHypergraphJSON_toHypergraph() {
        let events: [(source: [String], relation: String, target: [String])] = [
            (source: ["Apple"], relation: "launches", target: ["iPhone 16"]),
            (source: ["Samsung"], relation: "competes with", target: ["Apple"])
        ]

        let json = convertGenerableEventsToHypergraphJSON(events: events)
        let (hypergraph, metadata) = json.toHypergraph(chunkID: "test-chunk")

        XCTAssertEqual(metadata.count, 2)
        XCTAssertTrue(hypergraph.nodes.contains("Apple"))
        XCTAssertTrue(hypergraph.nodes.contains("iPhone 16"))
        XCTAssertTrue(hypergraph.nodes.contains("Samsung"))
    }

    // MARK: - Settings Defaults Tests

    func testOnDeviceChunkSizeDefault() {
        XCTAssertEqual(AppSettings.defaultOnDeviceChunkSize, 600)
    }

    func testOnDeviceExtractionPromptDefault() {
        let prompt = AppSettings.defaultOnDeviceExtractionPrompt
        XCTAssertFalse(prompt.isEmpty)
        XCTAssertTrue(prompt.localizedStandardContains("entity"))
        XCTAssertTrue(prompt.localizedStandardContains("relationships"))
    }

    func testClassificationProviderDefault() {
        XCTAssertEqual(AppSettings.defaultSimClassificationProvider, "openrouter")
    }

    // MARK: - LLMProviderOption Tests

    func testLLMProviderOption_onDeviceCase() {
        let option = LLMProviderOption.onDevice
        XCTAssertEqual(option.rawValue, "on_device")
        XCTAssertEqual(option.displayName, "On-Device (Apple Intelligence)")
    }

    func testLLMProviderOption_allCasesIncludesOnDevice() {
        XCTAssertTrue(LLMProviderOption.allCases.contains(.onDevice))
        XCTAssertEqual(LLMProviderOption.allCases.count, 4)
    }

    func testClassificationProviderOption_allCases() {
        XCTAssertEqual(ClassificationProviderOption.allCases.count, 2)
        XCTAssertTrue(ClassificationProviderOption.allCases.contains(.openrouter))
        XCTAssertTrue(ClassificationProviderOption.allCases.contains(.onDevice))
    }

    func testClassificationProviderOption_displayNames() {
        XCTAssertEqual(ClassificationProviderOption.openrouter.displayName, "OpenRouter (Cloud)")
        XCTAssertEqual(ClassificationProviderOption.onDevice.displayName, "On-Device (Apple Intelligence)")
    }

    // MARK: - NodeClassificationService Parsing Tests (existing behavior preserved)

    func testParseClassifications_stillWorksAfterRefactor() {
        let service = NodeClassificationService()
        let response = """
            [{"node_id": 1, "type": "person"}, {"node_id": 2, "type": "company"}]
            """

        let result = service.parseClassifications(from: response)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].nodeId, 1)
        XCTAssertEqual(result[0].type, "person")
        XCTAssertEqual(result[1].nodeId, 2)
        XCTAssertEqual(result[1].type, "company")
    }

    // MARK: - ClassificationError Tests

    func testClassificationError_onDeviceUnavailable() {
        let error = ClassificationError.onDeviceUnavailable
        XCTAssertNotNil(error.errorDescription)
        XCTAssertTrue(error.errorDescription!.localizedStandardContains("Apple Intelligence"))
    }

    // MARK: - inputSnippet Tests (empty-extraction logging)

    func testInputSnippet_stripsContextWrapper() {
        // Mirrors SystemPrompts.extractionUserPrompt's format.
        let prompt = "Context: ```Delta operates Atlanta-Washington flights.``` \n Extract the hypergraph knowledge graph in structured JSON format: "
        let snippet = FoundationModelService.inputSnippet(prompt)
        XCTAssertEqual(snippet, "Delta operates Atlanta-Washington flights.")
        XCTAssertFalse(snippet.contains("Context:"))
        XCTAssertFalse(snippet.contains("```"))
        XCTAssertFalse(snippet.contains("Extract the hypergraph"))
    }

    func testInputSnippet_collapsesNewlines() {
        let prompt = "Context: ```Line one.\nLine two.\n\nLine three.``` \n Extract: "
        let snippet = FoundationModelService.inputSnippet(prompt)
        XCTAssertEqual(snippet, "Line one. Line two. Line three.")
    }

    func testInputSnippet_truncatesLongInputWithEllipsis() {
        let body = String(repeating: "a", count: 500)
        let prompt = "Context: ```\(body)``` \n Extract: "
        let snippet = FoundationModelService.inputSnippet(prompt, limit: 240)
        XCTAssertEqual(snippet.count, 241) // 240 chars + ellipsis
        XCTAssertTrue(snippet.hasSuffix("…"))
    }

    func testInputSnippet_handlesMissingBackticks() {
        // Defensive: if the wrapper format ever changes, fall back to the raw text.
        let prompt = "no fences here, just text"
        let snippet = FoundationModelService.inputSnippet(prompt)
        XCTAssertEqual(snippet, "no fences here, just text")
    }

    func testInputSnippet_shortInputNotTruncated() {
        let prompt = "Context: ```short``` \n Extract: "
        let snippet = FoundationModelService.inputSnippet(prompt)
        XCTAssertEqual(snippet, "short")
        XCTAssertFalse(snippet.hasSuffix("…"))
    }
}
