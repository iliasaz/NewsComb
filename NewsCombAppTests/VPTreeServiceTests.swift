import XCTest
@testable import NewsCombApp

final class VPTreeServiceTests: XCTestCase {

    let service = VPTreeService()

    // MARK: - Basic Behavior

    func testEmptyInput() {
        let result = service.findAllKNN(vectors: [], k: 5)
        XCTAssertTrue(result.indices.isEmpty)
        XCTAssertTrue(result.distances.isEmpty)
    }

    func testSingleVector() {
        let result = service.findAllKNN(vectors: [[1, 2, 3]], k: 5)
        XCTAssertEqual(result.indices.count, 1)
        XCTAssertTrue(result.indices[0].isEmpty, "Single vector has no neighbors")
    }

    // MARK: - Correctness

    func testBruteForceAgreement() {
        // Verify VP-tree kNN matches brute-force for small data
        let vectors: [[Float]] = [
            [1.0, 0.0, 0.0],
            [0.9, 0.1, 0.0],
            [0.0, 1.0, 0.0],
            [0.0, 0.0, 1.0],
            [0.1, 0.9, 0.0],
        ]

        let k = 2
        let result = service.findAllKNN(vectors: vectors, k: k, metric: .euclidean)

        // Verify each point's neighbors via brute force
        for i in 0..<vectors.count {
            var distances: [(index: Int, distance: Float)] = []
            for j in 0..<vectors.count where j != i {
                let dist = euclideanDistance(vectors[i], vectors[j])
                distances.append((j, dist))
            }
            distances.sort { $0.distance < $1.distance }
            let expectedIndices = distances.prefix(k).map(\.index)

            XCTAssertEqual(Set(result.indices[i]), Set(expectedIndices),
                           "kNN for point \(i) should match brute force")
        }
    }

    func testCosineMetric() {
        // Vectors with different magnitudes but similar directions
        let vectors: [[Float]] = [
            [1.0, 0.0],   // direction 0°
            [10.0, 0.0],  // direction 0° (same direction, different magnitude)
            [0.0, 1.0],   // direction 90°
            [0.0, 10.0],  // direction 90° (same direction, different magnitude)
        ]

        let result = service.findAllKNN(vectors: vectors, k: 1, metric: .cosine)

        // Under cosine distance, [1,0] should be nearest to [10,0]
        XCTAssertEqual(result.indices[0].first, 1,
                       "[1,0] nearest neighbor under cosine should be [10,0]")
        XCTAssertEqual(result.indices[2].first, 3,
                       "[0,1] nearest neighbor under cosine should be [0,10]")
    }

    func testCorrectNumberOfNeighbors() {
        // Use diverse directions to avoid collinear vectors (cosine distance = 0)
        var vectors: [[Float]] = []
        for i in 0..<20 {
            let angle = Float(i) * 0.3
            vectors.append([cos(angle) + Float(i) * 0.1, sin(angle) + Float(i) * 0.05, Float(i) * 0.2])
        }

        let k = 5
        let result = service.findAllKNN(vectors: vectors, k: k, metric: .euclidean)

        for i in 0..<vectors.count {
            XCTAssertEqual(result.indices[i].count, k,
                           "Each point should have exactly \(k) neighbors")
            XCTAssertEqual(result.distances[i].count, k)

            // Distances should be non-negative and sorted ascending
            for j in 0..<k {
                XCTAssertGreaterThanOrEqual(result.distances[i][j], 0)
                if j > 0 {
                    XCTAssertLessThanOrEqual(result.distances[i][j - 1], result.distances[i][j],
                                             "Distances should be sorted ascending")
                }
            }

            // No self-references
            XCTAssertFalse(result.indices[i].contains(i),
                           "Point should not appear as its own neighbor")
        }
    }

    // MARK: - K Clamping

    func testKClampedToDataSize() {
        let vectors: [[Float]] = [[1, 0], [0, 1], [1, 1]]
        let result = service.findAllKNN(vectors: vectors, k: 10)

        // With 3 vectors, max k = 2 (n - 1)
        for i in 0..<3 {
            XCTAssertEqual(result.indices[i].count, 2,
                           "k should be clamped to n-1")
        }
    }

    // MARK: - Helpers

    private func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        let sum = zip(a, b).reduce(Float(0)) { acc, pair in
            let diff = pair.0 - pair.1
            return acc + diff * diff
        }
        return sqrt(sum)
    }
}
