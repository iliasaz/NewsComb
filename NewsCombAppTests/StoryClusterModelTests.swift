import XCTest
@testable import NewsCombApp

final class StoryClusterModelTests: XCTestCase {

    // MARK: - Top Entities Decoding

    func testTopEntitiesDecodeValid() {
        let json = """
        [{"label":"AWS","score":12.5},{"label":"Google Cloud","score":8.3}]
        """

        let cluster = StoryCluster(
            clusterId: 1, buildId: "test", label: "Test",
            size: 10, centroidVec: nil,
            topEntitiesJson: json, topRelFamiliesJson: nil,
            createdAt: Date()
        )

        let entities = cluster.topEntities
        XCTAssertEqual(entities.count, 2)
        XCTAssertEqual(entities[0].label, "AWS")
        XCTAssertEqual(entities[0].score, 12.5, accuracy: 0.01)
        XCTAssertEqual(entities[1].label, "Google Cloud")
    }

    func testTopEntitiesNilJson() {
        let cluster = StoryCluster(
            clusterId: 1, buildId: "test", label: nil,
            size: 0, centroidVec: nil,
            topEntitiesJson: nil, topRelFamiliesJson: nil,
            createdAt: Date()
        )

        XCTAssertTrue(cluster.topEntities.isEmpty)
    }

    func testTopEntitiesInvalidJson() {
        let cluster = StoryCluster(
            clusterId: 1, buildId: "test", label: nil,
            size: 0, centroidVec: nil,
            topEntitiesJson: "not json", topRelFamiliesJson: nil,
            createdAt: Date()
        )

        XCTAssertTrue(cluster.topEntities.isEmpty)
    }

    // MARK: - Top Relation Families Decoding

    func testTopRelFamiliesDecodeValid() {
        let json = """
        [{"family":"Partnership","count":15},{"family":"Product Launch","count":8}]
        """

        let cluster = StoryCluster(
            clusterId: 1, buildId: "test", label: nil,
            size: 0, centroidVec: nil,
            topEntitiesJson: nil, topRelFamiliesJson: json,
            createdAt: Date()
        )

        let families = cluster.topRelFamilies
        XCTAssertEqual(families.count, 2)
        XCTAssertEqual(families[0].family, "Partnership")
        XCTAssertEqual(families[0].count, 15)
    }

    func testTopRelFamiliesNilJson() {
        let cluster = StoryCluster(
            clusterId: 1, buildId: "test", label: nil,
            size: 0, centroidVec: nil,
            topEntitiesJson: nil, topRelFamiliesJson: nil,
            createdAt: Date()
        )

        XCTAssertTrue(cluster.topRelFamilies.isEmpty)
    }

    // MARK: - Hashable Conformance

    func testHashableByClusterId() {
        let c1 = StoryCluster(
            clusterId: 1, buildId: "a", label: "One",
            size: 10, centroidVec: nil,
            topEntitiesJson: nil, topRelFamiliesJson: nil,
            createdAt: Date()
        )
        let c2 = StoryCluster(
            clusterId: 1, buildId: "a", label: "One",
            size: 10, centroidVec: nil,
            topEntitiesJson: nil, topRelFamiliesJson: nil,
            createdAt: Date()
        )

        XCTAssertEqual(c1.hashValue, c2.hashValue)
    }

    // MARK: - Identifiable

    func testIdMatchesClusterId() {
        let cluster = StoryCluster(
            clusterId: 42, buildId: "test", label: nil,
            size: 0, centroidVec: nil,
            topEntitiesJson: nil, topRelFamiliesJson: nil,
            createdAt: Date()
        )

        XCTAssertEqual(cluster.id, 42)
    }

    // MARK: - RankedEntity

    func testRankedEntityIdentifiable() {
        let entity = RankedEntity(label: "AWS", score: 12.5)
        XCTAssertEqual(entity.id, "AWS")
    }

    // MARK: - RankedFamily

    func testRankedFamilyIdentifiable() {
        let family = RankedFamily(family: "Partnership", count: 15)
        XCTAssertEqual(family.id, "Partnership")
    }
}
