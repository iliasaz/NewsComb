import XCTest
@testable import NewsCombApp

final class PCAServiceTests: XCTestCase {

    let service = PCAService()

    // MARK: - Basic Behavior

    func testEmptyInput() {
        let result = service.project(vectors: [])
        XCTAssertTrue(result.projectedVectors.isEmpty)
    }

    func testSingleVector() {
        let result = service.project(vectors: [[1, 2, 3, 4, 5]])
        // With only 1 vector, PCA returns unchanged (n < 2)
        XCTAssertEqual(result.projectedVectors.count, 1)
        XCTAssertEqual(result.projectedVectors[0], [1, 2, 3, 4, 5])
    }

    func testTargetDimLargerThanInput() {
        let vectors: [[Float]] = [[1, 2], [3, 4], [5, 6]]
        let params = PCAService.Parameters(targetDimension: 10)
        let result = service.project(vectors: vectors, params: params)
        // Target dim > input dim → skip PCA, return original
        XCTAssertEqual(result.projectedVectors, vectors)
        XCTAssertEqual(result.explainedVarianceRatio, 1.0)
    }

    // MARK: - Dimensionality Reduction

    func testOutputDimension() {
        // 20 vectors of 10 dimensions → project to 3D
        var vectors: [[Float]] = []
        for i in 0..<20 {
            vectors.append((0..<10).map { Float(i * 10 + $0) + Float.random(in: -0.1...0.1) })
        }

        let params = PCAService.Parameters(targetDimension: 3)
        let result = service.project(vectors: vectors, params: params)

        XCTAssertEqual(result.projectedVectors.count, 20)
        for vec in result.projectedVectors {
            XCTAssertEqual(vec.count, 3, "Each projected vector should have 3 dimensions")
        }
    }

    func testVariancePreservation() {
        // Create data with clear principal axis: most variance along dim 0
        var vectors: [[Float]] = []
        for i in 0..<50 {
            let x = Float(i) * 2.0  // High variance
            let y = Float.random(in: -0.1...0.1)  // Low variance
            let z = Float.random(in: -0.1...0.1)  // Low variance
            let w = Float.random(in: -0.1...0.1)  // Low variance
            vectors.append([x, y, z, w])
        }

        let params = PCAService.Parameters(targetDimension: 1)
        let result = service.project(vectors: vectors, params: params)

        // First PC should capture most of the variance since dim 0 dominates
        XCTAssertGreaterThan(result.explainedVarianceRatio, 0.9,
                             "First PC should capture >90% variance when one dimension dominates")
    }

    func testHighDimensionalReduction() {
        // Simulate the real use case: 100 vectors of 100D → 10D
        var vectors: [[Float]] = []
        for i in 0..<100 {
            vectors.append((0..<100).map { _ in Float(i) * 0.01 + Float.random(in: -1...1) })
        }

        let params = PCAService.Parameters(targetDimension: 10)
        let result = service.project(vectors: vectors, params: params)

        XCTAssertEqual(result.projectedVectors.count, 100)
        XCTAssertEqual(result.projectedVectors[0].count, 10)
        XCTAssertGreaterThan(result.explainedVarianceRatio, 0,
                             "Explained variance should be positive")
        XCTAssertLessThanOrEqual(result.explainedVarianceRatio, 1.0,
                                  "Explained variance should be <= 1.0")
    }

    // MARK: - Determinism

    func testDeterministic() {
        var vectors: [[Float]] = []
        for i in 0..<30 {
            vectors.append((0..<8).map { Float(i * 8 + $0) })
        }

        let params = PCAService.Parameters(targetDimension: 3)
        let result1 = service.project(vectors: vectors, params: params)
        let result2 = service.project(vectors: vectors, params: params)

        XCTAssertEqual(result1.projectedVectors.count, result2.projectedVectors.count)
        for i in 0..<result1.projectedVectors.count {
            for j in 0..<result1.projectedVectors[i].count {
                XCTAssertEqual(result1.projectedVectors[i][j],
                               result2.projectedVectors[i][j],
                               accuracy: 1e-5,
                               "PCA should be deterministic")
            }
        }
    }

    // MARK: - Target Dim Clamped to N

    func testTargetDimClampedToNumberOfVectors() {
        // 3 vectors of 10D, target 5D → should clamp to min(5, 10, 3) = 3
        let vectors: [[Float]] = [
            [1, 2, 3, 4, 5, 6, 7, 8, 9, 10],
            [2, 3, 4, 5, 6, 7, 8, 9, 10, 11],
            [3, 4, 5, 6, 7, 8, 9, 10, 11, 12],
        ]
        let params = PCAService.Parameters(targetDimension: 5)
        let result = service.project(vectors: vectors, params: params)

        // k = min(5, 10, 3) = 3
        XCTAssertEqual(result.projectedVectors[0].count, 3)
    }

    // MARK: - Structure Preservation

    func testRelativeDistancesPreserved() {
        // Two clusters: close pair and far pair
        // After PCA, relative ordering should be preserved
        let clusterA: [[Float]] = [
            [1.0, 1.0, 0, 0, 0],
            [1.1, 0.9, 0, 0, 0],
            [0.9, 1.1, 0, 0, 0],
        ]
        let clusterB: [[Float]] = [
            [10.0, 10.0, 0, 0, 0],
            [10.1, 9.9, 0, 0, 0],
            [9.9, 10.1, 0, 0, 0],
        ]
        let vectors = clusterA + clusterB

        let params = PCAService.Parameters(targetDimension: 2)
        let result = service.project(vectors: vectors, params: params)

        // Points within clusterA should be closer to each other than to clusterB
        let p0 = result.projectedVectors[0]
        let p1 = result.projectedVectors[1]
        let p3 = result.projectedVectors[3]

        let withinDist = euclideanDistance(p0, p1)
        let betweenDist = euclideanDistance(p0, p3)

        XCTAssertLessThan(withinDist, betweenDist,
                          "Within-cluster distances should be smaller than between-cluster")
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
