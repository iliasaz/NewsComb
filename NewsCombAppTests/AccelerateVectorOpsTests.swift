import XCTest
@testable import NewsCombApp

/// Deterministic, seedable PRNG so tests don't randomly straddle the threshold
/// boundary. `cblas_sgemm` can produce ~1 ULP rounding differences at different
/// internal blockings, so any test that compares pair counts across block sizes
/// must keep all similarity values comfortably away from the threshold — easier
/// when the inputs are reproducible.
private struct SeededPRNG: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { self.state = seed | 1 }
    mutating func next() -> UInt64 {
        // SplitMix64 — small, well-distributed, good enough for tests.
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

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

    func testFindSimilarPairsBlockSizeIndependence() {
        // The blocked implementation must return the same pairs for any
        // block size from 1 up to and beyond N. This guards against
        // off-by-one bugs at block boundaries (especially the upper-triangle
        // mask that depends on the global row index).
        var rng = SeededPRNG(seed: 0xC0FFEE_BADC0DE)
        var embeddings: [[Float]] = []
        for _ in 0..<37 {
            var vec = [Float]()
            for _ in 0..<16 {
                vec.append(Float.random(in: -1...1, using: &rng))
            }
            embeddings.append(vec)
        }
        // Inject a few near-duplicates so we get non-empty results.
        embeddings.append(embeddings[3].map { $0 * 1.01 })
        embeddings.append(embeddings[10].map { $0 + 0.001 })

        let reference = AccelerateVectorOps.findSimilarPairs(
            embeddings: embeddings, threshold: 0.5, blockSize: embeddings.count
        )

        for block in [1, 2, 3, 7, 16, 32, 64, 128] {
            let actual = AccelerateVectorOps.findSimilarPairs(
                embeddings: embeddings, threshold: 0.5, blockSize: block
            )
            XCTAssertEqual(actual.count, reference.count, "block=\(block) pair count mismatch")
            for (a, r) in zip(actual, reference) {
                XCTAssertEqual(a.i, r.i, "block=\(block) i mismatch")
                XCTAssertEqual(a.j, r.j, "block=\(block) j mismatch")
                XCTAssertEqual(a.similarity, r.similarity, accuracy: 1e-4, "block=\(block) sim mismatch")
            }
        }
    }

    func testFindSimilarPairsSortedDescending() {
        // Three identical pairs at different similarity levels; verify the
        // output is sorted highest-similarity first.
        let embeddings: [[Float]] = [
            [1, 0, 0],
            [0.999, 0.001, 0],   // ~1.0
            [0.95, 0.05, 0],     // ~0.95
            [0.92, 0.08, 0]      // ~0.92
        ]

        let pairs = AccelerateVectorOps.findSimilarPairs(embeddings: embeddings, threshold: 0.9, blockSize: 2)

        XCTAssertGreaterThanOrEqual(pairs.count, 3)
        for k in 1..<pairs.count {
            XCTAssertGreaterThanOrEqual(pairs[k - 1].similarity, pairs[k].similarity)
        }
    }

    func testFindSimilarPairsUpperTriangleOnly() {
        // All pairs must satisfy i < j.
        let embeddings: [[Float]] = (0..<20).map { idx in
            var v = [Float](repeating: 0, count: 8)
            v[idx % 8] = 1
            v[(idx + 1) % 8] = Float(idx) * 0.05
            return v
        }
        let pairs = AccelerateVectorOps.findSimilarPairs(embeddings: embeddings, threshold: 0.0, blockSize: 4)
        for p in pairs {
            XCTAssertLessThan(p.i, p.j)
        }
    }

    func testFindSimilarPairsMatchesBruteForce() {
        // Cross-check against a naive O(N²) reference computed via
        // `cosineSimilarity` to confirm the blocked path is semantically
        // identical to the original code path.
        var rng = SeededPRNG(seed: 0xDEAD_BEEF_CAFE)
        var embeddings: [[Float]] = []
        for _ in 0..<24 {
            var vec = [Float]()
            for _ in 0..<12 {
                vec.append(Float.random(in: -1...1, using: &rng))
            }
            embeddings.append(vec)
        }

        let threshold: Float = 0.3
        var brute: [AccelerateVectorOps.SimilarPair] = []
        for i in 0..<embeddings.count {
            for j in (i + 1)..<embeddings.count {
                let sim = AccelerateVectorOps.cosineSimilarity(embeddings[i], embeddings[j])
                if sim > threshold {
                    brute.append(AccelerateVectorOps.SimilarPair(i: i, j: j, similarity: sim))
                }
            }
        }
        brute.sort { $0.similarity > $1.similarity }

        let actual = AccelerateVectorOps.findSimilarPairs(
            embeddings: embeddings, threshold: threshold, blockSize: 5
        )

        XCTAssertEqual(actual.count, brute.count)
        for (a, b) in zip(actual, brute) {
            XCTAssertEqual(a.i, b.i)
            XCTAssertEqual(a.j, b.j)
            XCTAssertEqual(a.similarity, b.similarity, accuracy: 1e-4)
        }
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
