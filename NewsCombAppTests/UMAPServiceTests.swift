import XCTest
@testable import NewsCombApp

final class UMAPServiceTests: XCTestCase {

    let service = UMAPService()

    // MARK: - Basic Behavior

    func testEmptyInput() async throws {
        let result = try await service.reduce(vectors: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testSingleVector() async throws {
        let result = try await service.reduce(vectors: [[1, 2, 3]])
        // With only 1 vector, UMAP returns unchanged (n < 2)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0], [1, 2, 3])
    }

    func testTargetDimensionGreaterOrEqualToInputReturnsInput() async throws {
        // 4 vectors of 3 dims; ask to "reduce" to 3D — short-circuits, no MLX call.
        let vectors: [[Float]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]]
        let params = UMAPService.Parameters(targetDimension: 3, nNeighbors: 2)
        let result = try await service.reduce(vectors: vectors, params: params)
        XCTAssertEqual(result, vectors)
    }

    // MARK: - Output Dimensions

    func testOutputDimension() async throws {
        var vectors: [[Float]] = []
        for i in 0..<30 {
            vectors.append((0..<10).map { Float(i * 10 + $0) * 0.01 })
        }

        let params = UMAPService.Parameters(
            targetDimension: 3,
            nNeighbors: 5,
            nEpochs: 50
        )
        let result = try await service.reduce(vectors: vectors, params: params)

        XCTAssertEqual(result.count, 30, "Should return same number of vectors")
        for vec in result {
            XCTAssertEqual(vec.count, 3, "Each vector should have target dimension")
        }
    }

    // MARK: - Cluster Separation

    func testClustersSeparated() async throws {
        var vectors: [[Float]] = []

        for _ in 0..<15 {
            let noise = (0..<5).map { _ in Float.random(in: -0.05...0.05) }
            var v: [Float] = [1.0 + noise[0], 1.0 + noise[1], noise[2], noise[3], noise[4]]
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            v = v.map { $0 / norm }
            vectors.append(v)
        }
        for _ in 0..<15 {
            let noise = (0..<5).map { _ in Float.random(in: -0.05...0.05) }
            var v: [Float] = [noise[0], noise[1], 1.0 + noise[2], 1.0 + noise[3], noise[4]]
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            v = v.map { $0 / norm }
            vectors.append(v)
        }

        let params = UMAPService.Parameters(
            targetDimension: 2,
            nNeighbors: 5,
            nEpochs: 100
        )
        let result = try await service.reduce(vectors: vectors, params: params)

        let meanA = meanVector(Array(result[0..<15]))
        let meanB = meanVector(Array(result[15..<30]))
        let dist = euclideanDistance(meanA, meanB)
        XCTAssertGreaterThan(dist, 0.1,
                             "Cluster centroids should be separated in the UMAP embedding")
    }

    // MARK: - Determinism

    func testNeighborhoodPreservation() async throws {
        var vectors: [[Float]] = []
        for _ in 0..<15 {
            vectors.append([1.0 + Float.random(in: -0.1...0.1),
                            0.0 + Float.random(in: -0.1...0.1),
                            0.0 + Float.random(in: -0.1...0.1)])
        }
        for _ in 0..<15 {
            vectors.append([0.0 + Float.random(in: -0.1...0.1),
                            1.0 + Float.random(in: -0.1...0.1),
                            0.0 + Float.random(in: -0.1...0.1)])
        }

        let params = UMAPService.Parameters(
            targetDimension: 2,
            nNeighbors: 5,
            nEpochs: 100
        )
        let result = try await service.reduce(vectors: vectors, params: params)

        var withinDistances: [Float] = []
        var betweenDistances: [Float] = []

        for i in 0..<15 {
            for j in (i + 1)..<15 {
                withinDistances.append(euclideanDistance(result[i], result[j]))
            }
        }
        for i in 0..<15 {
            for j in 15..<30 {
                betweenDistances.append(euclideanDistance(result[i], result[j]))
            }
        }

        let meanWithin = withinDistances.reduce(0, +) / Float(withinDistances.count)
        let meanBetween = betweenDistances.reduce(0, +) / Float(betweenDistances.count)

        XCTAssertLessThan(meanWithin, meanBetween,
                          "Within-cluster distances (\(meanWithin)) should be less than between-cluster (\(meanBetween))")
    }

    // MARK: - Edge Cases

    func testTwoVectors() async throws {
        let vectors: [[Float]] = [[1, 0, 0], [0, 1, 0]]
        let params = UMAPService.Parameters(
            targetDimension: 2,
            nNeighbors: 1,
            nEpochs: 20
        )
        let result = try await service.reduce(vectors: vectors, params: params)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].count, 2)
    }

    func testFewNeighborsClampedToDataSize() async throws {
        var vectors: [[Float]] = []
        for i in 0..<5 {
            vectors.append([Float(i), Float(i) * 2])
        }

        let params = UMAPService.Parameters(
            targetDimension: 2,
            nNeighbors: 10,
            nEpochs: 20
        )
        let result = try await service.reduce(vectors: vectors, params: params)
        XCTAssertEqual(result.count, 5)
    }

    // MARK: - Helpers

    private func meanVector(_ vectors: [[Float]]) -> [Float] {
        guard let first = vectors.first else { return [] }
        var mean = [Float](repeating: 0, count: first.count)
        for vec in vectors {
            for i in 0..<vec.count {
                mean[i] += vec[i]
            }
        }
        let n = Float(vectors.count)
        return mean.map { $0 / n }
    }

    private func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        let sum = zip(a, b).reduce(Float(0)) { acc, pair in
            let diff = pair.0 - pair.1
            return acc + diff * diff
        }
        return sqrt(sum)
    }
}
