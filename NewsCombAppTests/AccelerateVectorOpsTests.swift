import XCTest
@testable import NewsCombApp

final class AccelerateVectorOpsTests: XCTestCase {

    // MARK: - Cosine Similarity Tests

    func testCosineSimilarityIdenticalVectors() {
        let a: [Float] = [1, 2, 3, 4, 5]
        let b: [Float] = [1, 2, 3, 4, 5]

        let similarity = AccelerateVectorOps.cosineSimilarity(a, b)

        XCTAssertEqual(similarity, 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]

        let similarity = AccelerateVectorOps.cosineSimilarity(a, b)

        XCTAssertEqual(similarity, 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarityOppositeVectors() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]

        let similarity = AccelerateVectorOps.cosineSimilarity(a, b)

        XCTAssertEqual(similarity, -1.0, accuracy: 0.0001)
    }

    func testCosineSimilaritySimilarVectors() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1.1, 2.1, 3.1]

        let similarity = AccelerateVectorOps.cosineSimilarity(a, b)

        // Should be very close to 1 but not exactly 1
        XCTAssertGreaterThan(similarity, 0.99)
        XCTAssertLessThan(similarity, 1.0)
    }

    func testCosineSimilarityEmptyVectors() {
        let a: [Float] = []
        let b: [Float] = []

        let similarity = AccelerateVectorOps.cosineSimilarity(a, b)

        XCTAssertEqual(similarity, 0.0)
    }

    // MARK: - Similarity Matrix Tests

    func testCosineSimilarityMatrixSingleVector() {
        let embeddings: [[Float]] = [[1, 2, 3]]

        let matrix = AccelerateVectorOps.cosineSimilarityMatrix(embeddings)

        XCTAssertEqual(matrix.count, 1)
        XCTAssertEqual(matrix[0].count, 1)
        XCTAssertEqual(matrix[0][0], 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityMatrixTwoVectors() {
        let embeddings: [[Float]] = [
            [1, 0, 0],
            [0, 1, 0]
        ]

        let matrix = AccelerateVectorOps.cosineSimilarityMatrix(embeddings)

        XCTAssertEqual(matrix.count, 2)
        XCTAssertEqual(matrix[0][0], 1.0, accuracy: 0.0001)  // Self-similarity
        XCTAssertEqual(matrix[1][1], 1.0, accuracy: 0.0001)  // Self-similarity
        XCTAssertEqual(matrix[0][1], 0.0, accuracy: 0.0001)  // Orthogonal
        XCTAssertEqual(matrix[1][0], 0.0, accuracy: 0.0001)  // Orthogonal
    }

    func testCosineSimilarityMatrixSymmetry() {
        let embeddings: [[Float]] = [
            [1, 2, 3],
            [4, 5, 6],
            [7, 8, 9]
        ]

        let matrix = AccelerateVectorOps.cosineSimilarityMatrix(embeddings)

        XCTAssertEqual(matrix.count, 3)

        // Verify symmetry: matrix[i][j] == matrix[j][i]
        for i in 0..<3 {
            for j in 0..<3 {
                XCTAssertEqual(matrix[i][j], matrix[j][i], accuracy: 0.0001)
            }
        }
    }

    func testCosineSimilarityMatrixEmpty() {
        let embeddings: [[Float]] = []

        let matrix = AccelerateVectorOps.cosineSimilarityMatrix(embeddings)

        XCTAssertTrue(matrix.isEmpty)
    }

    // MARK: - Top-K Similar Tests

    func testTopKSimilar() {
        let query: [Float] = [1, 0, 0]
        let embeddings: [[Float]] = [
            [1, 0, 0],       // Identical to query
            [0.9, 0.1, 0],   // Very similar
            [0, 1, 0],       // Orthogonal
            [-1, 0, 0]       // Opposite
        ]

        let results = AccelerateVectorOps.topKSimilar(query: query, embeddings: embeddings, k: 2)

        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results[0].index, 0)  // Identical vector should be first
        XCTAssertEqual(results[1].index, 1)  // Second most similar
    }

    func testTopKSimilarMoreThanK() {
        let query: [Float] = [1, 1, 1]
        let embeddings: [[Float]] = [
            [1, 1, 1],
            [2, 2, 2],
            [3, 3, 3]
        ]

        let results = AccelerateVectorOps.topKSimilar(query: query, embeddings: embeddings, k: 5)

        // Should return all 3, even though k=5
        XCTAssertEqual(results.count, 3)
    }

    // MARK: - Find Similar Pairs Tests

    func testFindSimilarPairs() {
        let embeddings: [[Float]] = [
            [1, 0, 0],          // Index 0
            [0.99, 0.01, 0],    // Index 1 - very similar to 0
            [0, 1, 0],          // Index 2 - orthogonal
            [0, 0, 1]           // Index 3 - orthogonal
        ]

        let pairs = AccelerateVectorOps.findSimilarPairs(embeddings: embeddings, threshold: 0.95)

        // Should find pair (0, 1) above threshold 0.95
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs[0].i, 0)
        XCTAssertEqual(pairs[0].j, 1)
        XCTAssertGreaterThan(pairs[0].similarity, 0.95)
    }

    func testFindSimilarPairsNoPairs() {
        let embeddings: [[Float]] = [
            [1, 0, 0],
            [0, 1, 0],
            [0, 0, 1]
        ]

        let pairs = AccelerateVectorOps.findSimilarPairs(embeddings: embeddings, threshold: 0.5)

        XCTAssertTrue(pairs.isEmpty)
    }

    // MARK: - L2 Distance Tests

    func testL2DistanceIdenticalVectors() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1, 2, 3]

        let distance = AccelerateVectorOps.l2Distance(a, b)

        XCTAssertEqual(distance, 0.0, accuracy: 0.0001)
    }

    func testL2DistanceKnownValue() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [3, 4, 0]

        let distance = AccelerateVectorOps.l2Distance(a, b)

        // sqrt(3^2 + 4^2) = 5
        XCTAssertEqual(distance, 5.0, accuracy: 0.0001)
    }

    // MARK: - Normalize Tests

    func testNormalizeUnitVector() {
        let vector: [Float] = [1, 0, 0]

        let normalized = AccelerateVectorOps.normalize(vector)

        XCTAssertEqual(normalized[0], 1.0, accuracy: 0.0001)
        XCTAssertEqual(normalized[1], 0.0, accuracy: 0.0001)
        XCTAssertEqual(normalized[2], 0.0, accuracy: 0.0001)
    }

    func testNormalizeNonUnitVector() {
        let vector: [Float] = [3, 4, 0]

        let normalized = AccelerateVectorOps.normalize(vector)

        // Should have unit length
        let length = sqrt(normalized[0] * normalized[0] + normalized[1] * normalized[1] + normalized[2] * normalized[2])
        XCTAssertEqual(length, 1.0, accuracy: 0.0001)

        // Direction should be preserved
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.0001)  // 3/5
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.0001)  // 4/5
    }

    func testNormalizeEmptyVector() {
        let vector: [Float] = []

        let normalized = AccelerateVectorOps.normalize(vector)

        XCTAssertTrue(normalized.isEmpty)
    }
}
