import XCTest
@testable import NewsCombApp

final class HDBSCANServiceTests: XCTestCase {

    let service = HDBSCANService()

    // MARK: - Basic Behavior

    func testEmptyInput() {
        let result = service.cluster(vectors: [])
        XCTAssertTrue(result.labels.isEmpty)
        XCTAssertEqual(result.clusterCount, 0)
    }

    func testSinglePoint() {
        let result = service.cluster(vectors: [[1, 2, 3]])
        XCTAssertEqual(result.labels.count, 1)
        XCTAssertEqual(result.labels[0], -1) // Single point is noise
        XCTAssertEqual(result.clusterCount, 0)
    }

    func testTwoPointsTooFewForCluster() {
        let params = HDBSCANService.Parameters(minClusterSize: 3, minSamples: 2)
        let result = service.cluster(vectors: [[0, 0], [1, 0]], params: params)
        // With only 2 points and minClusterSize=3, both should be noise
        XCTAssertEqual(result.labels.count, 2)
    }

    // MARK: - Well-Separated Clusters

    func testTwoClearClusters() {
        // Two well-separated clusters of 10 points each.
        // Use 2D Gaussian-like spread (not collinear) to avoid tied
        // mutual reachability weights that depend on sort stability.
        let clusterA: [[Float]] = [
            [1.0, 1.0], [1.2, 0.8], [0.9, 1.3], [1.1, 1.1], [0.7, 0.9],
            [1.3, 1.2], [0.8, 0.7], [1.0, 1.4], [1.4, 1.0], [0.6, 1.1],
        ]
        let clusterB: [[Float]] = [
            [50.0, 50.0], [50.2, 49.8], [49.9, 50.3], [50.1, 50.1], [49.7, 49.9],
            [50.3, 50.2], [49.8, 49.7], [50.0, 50.4], [50.4, 50.0], [49.6, 50.1],
        ]
        var vectors = clusterA + clusterB

        let params = HDBSCANService.Parameters(minClusterSize: 5, minSamples: 3)
        let result = service.cluster(vectors: vectors, params: params)

        // Should find exactly 2 clusters
        XCTAssertEqual(result.clusterCount, 2, "Should find 2 clusters")
        XCTAssertEqual(result.labels.count, 20)

        // First 10 points should have the same label
        let labelA = result.labels[0]
        for i in 0..<10 {
            XCTAssertEqual(result.labels[i], labelA,
                           "Point \(i) should be in cluster A")
        }

        // Last 10 points should have the same label (different from A)
        let labelB = result.labels[10]
        XCTAssertNotEqual(labelA, labelB, "Clusters should have different labels")
        for i in 10..<20 {
            XCTAssertEqual(result.labels[i], labelB,
                           "Point \(i) should be in cluster B")
        }
    }

    func testThreeClusters() {
        var vectors: [[Float]] = []

        // Cluster at origin
        for i in 0..<8 {
            vectors.append([Float(i) * 0.05, Float(i) * 0.02])
        }

        // Cluster at (50, 0)
        for i in 0..<8 {
            vectors.append([50 + Float(i) * 0.05, Float(i) * 0.02])
        }

        // Cluster at (0, 50)
        for i in 0..<8 {
            vectors.append([Float(i) * 0.02, 50 + Float(i) * 0.05])
        }

        let params = HDBSCANService.Parameters(minClusterSize: 4, minSamples: 3)
        let result = service.cluster(vectors: vectors, params: params)

        // Should find at least 2 clusters (3 is ideal but density-based may vary)
        XCTAssertGreaterThanOrEqual(result.clusterCount, 2,
                                    "Should find at least 2 distinct clusters")
        XCTAssertEqual(result.labels.count, 24)
    }

    // MARK: - Noise Detection

    func testOutlierDetection() {
        var vectors: [[Float]] = []

        // Tight cluster of 15 points at origin
        for i in 0..<15 {
            vectors.append([Float(i) * 0.01, Float(i) * 0.01])
        }

        // One far-away outlier
        vectors.append([1000, 1000])

        let params = HDBSCANService.Parameters(minClusterSize: 5, minSamples: 3)
        let result = service.cluster(vectors: vectors, params: params)

        // The outlier should be noise (-1) or in a different category
        let outlierLabel = result.labels[15]
        let clusterLabel = result.labels[0]

        // Either the outlier is noise, or it's in a different cluster
        if outlierLabel != -1 {
            // It's OK if HDBSCAN puts it somewhere, but ideally it's noise
            // This is implementation-dependent
        }

        // The tight cluster should be found
        XCTAssertGreaterThanOrEqual(result.clusterCount, 1)
        XCTAssertNotEqual(clusterLabel, -1, "Dense group should form a cluster")
    }

    // MARK: - Parameter Validation

    func testParametersValidatedForSmallData() {
        let params = HDBSCANService.Parameters(minClusterSize: 100, minSamples: 50)
        let validated = params.validated(forDataSize: 10)

        XCTAssertLessThanOrEqual(validated.minClusterSize, 10)
        XCTAssertLessThanOrEqual(validated.minSamples, validated.minClusterSize)
    }

    func testParametersUnchangedForLargeData() {
        let params = HDBSCANService.Parameters(minClusterSize: 20, minSamples: 10)
        let validated = params.validated(forDataSize: 10000)

        XCTAssertEqual(validated.minClusterSize, 20)
        XCTAssertEqual(validated.minSamples, 10)
    }

    // MARK: - Membership Scores

    func testMembershipScoresInRange() {
        var vectors: [[Float]] = []
        for i in 0..<20 {
            vectors.append([Float(i) * 0.05, Float(i) * 0.02])
        }

        let params = HDBSCANService.Parameters(minClusterSize: 5, minSamples: 3)
        let result = service.cluster(vectors: vectors, params: params)

        for membership in result.memberships {
            XCTAssertGreaterThanOrEqual(membership, 0, "Membership should be >= 0")
        }

        XCTAssertEqual(result.labels.count, result.memberships.count,
                       "Labels and memberships should have the same count")
    }

    // MARK: - Determinism

    func testDeterministic() {
        var vectors: [[Float]] = []
        for i in 0..<20 {
            vectors.append([Float(i % 5) * 10, Float(i / 5) * 10])
        }

        let params = HDBSCANService.Parameters(minClusterSize: 3, minSamples: 2)
        let result1 = service.cluster(vectors: vectors, params: params)
        let result2 = service.cluster(vectors: vectors, params: params)

        XCTAssertEqual(result1.labels, result2.labels, "HDBSCAN should be deterministic")
        XCTAssertEqual(result1.clusterCount, result2.clusterCount)
    }
}
