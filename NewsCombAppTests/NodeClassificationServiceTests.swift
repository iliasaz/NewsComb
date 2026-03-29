import XCTest
@testable import NewsCombApp

final class NodeClassificationServiceTests: XCTestCase {

    private let service = NodeClassificationService()

    // MARK: - parseClassifications Tests

    func testParseClassifications_validJSON() {
        let response = """
            [{"node_id": 1, "type": "person"}, {"node_id": 2, "type": "organization"}, {"node_id": 3, "type": "company"}]
            """

        let result = service.parseClassifications(from: response)

        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result[0].nodeId, 1)
        XCTAssertEqual(result[0].type, "person")
        XCTAssertEqual(result[1].nodeId, 2)
        XCTAssertEqual(result[1].type, "organization")
        XCTAssertEqual(result[2].nodeId, 3)
        XCTAssertEqual(result[2].type, "company")
    }

    func testParseClassifications_withMarkdownCodeBlock() {
        let response = """
            Here are the classifications:

            ```json
            [{"node_id": 10, "type": "government"}, {"node_id": 20, "type": "location"}]
            ```

            These are based on the context provided.
            """

        let result = service.parseClassifications(from: response)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].nodeId, 10)
        XCTAssertEqual(result[0].type, "government_entity")
        XCTAssertEqual(result[1].nodeId, 20)
        XCTAssertEqual(result[1].type, "non-actor")
    }

    func testParseClassifications_invalidType() {
        let response = """
            [{"node_id": 1, "type": "person"}, {"node_id": 2, "type": "alien"}, {"node_id": 3, "type": "company"}]
            """

        let result = service.parseClassifications(from: response)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].nodeId, 1)
        XCTAssertEqual(result[0].type, "person")
        XCTAssertEqual(result[1].nodeId, 3)
        XCTAssertEqual(result[1].type, "company")
    }

    func testParseClassifications_emptyResponse() {
        let result = service.parseClassifications(from: "")
        XCTAssertTrue(result.isEmpty)
    }

    func testParseClassifications_partialJSON() {
        let response = """
            Based on the entity names and their relationships, here is my classification:

            The entities can be classified as follows:
            [{"node_id": 5, "type": "media"}, {"node_id": 6, "type": "product"}]

            Note that some entities could fit multiple categories.
            """

        let result = service.parseClassifications(from: response)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].nodeId, 5)
        XCTAssertEqual(result[0].type, "organization")
        XCTAssertEqual(result[1].nodeId, 6)
        XCTAssertEqual(result[1].type, "non-actor")
    }

    func testParseClassifications_allValidTypes() {
        let response = """
            [
                {"node_id": 1, "type": "person"},
                {"node_id": 2, "type": "organization"},
                {"node_id": 3, "type": "company"},
                {"node_id": 4, "type": "government_entity"},
                {"node_id": 5, "type": "institution"},
                {"node_id": 6, "type": "non-actor"}
            ]
            """

        let result = service.parseClassifications(from: response)
        XCTAssertEqual(result.count, 6)
    }

    func testParseClassifications_aliasesMapCorrectly() {
        let response = """
            [
                {"node_id": 1, "type": "government"},
                {"node_id": 2, "type": "government body"},
                {"node_id": 3, "type": "agency"},
                {"node_id": 4, "type": "media"},
                {"node_id": 5, "type": "ngo"},
                {"node_id": 6, "type": "product"},
                {"node_id": 7, "type": "concept"},
                {"node_id": 8, "type": "event"},
                {"node_id": 9, "type": "location"},
                {"node_id": 10, "type": "other"}
            ]
            """

        let result = service.parseClassifications(from: response)
        XCTAssertEqual(result.count, 10)
        // government variants -> government_entity
        XCTAssertEqual(result[0].type, "government_entity")
        XCTAssertEqual(result[1].type, "government_entity")
        XCTAssertEqual(result[2].type, "government_entity")
        // media, ngo -> organization
        XCTAssertEqual(result[3].type, "organization")
        XCTAssertEqual(result[4].type, "organization")
        // product, concept, event, location, other -> non-actor
        XCTAssertEqual(result[5].type, "non-actor")
        XCTAssertEqual(result[6].type, "non-actor")
        XCTAssertEqual(result[7].type, "non-actor")
        XCTAssertEqual(result[8].type, "non-actor")
        XCTAssertEqual(result[9].type, "non-actor")
    }

    func testParseClassifications_normalizesCase() {
        let response = """
            [{"node_id": 1, "type": "Person"}, {"node_id": 2, "type": "COMPANY"}]
            """

        let result = service.parseClassifications(from: response)

        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].type, "person")
        XCTAssertEqual(result[1].type, "company")
    }

    func testParseClassifications_malformedJSON() {
        let response = "This is not JSON at all, just plain text."

        let result = service.parseClassifications(from: response)
        XCTAssertTrue(result.isEmpty)
    }
}
