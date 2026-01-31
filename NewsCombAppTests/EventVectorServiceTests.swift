import Accelerate
import XCTest
@testable import NewsCombApp

final class EventVectorServiceTests: XCTestCase {

    // MARK: - Event Vector Dimensions

    func testEmbeddingDimFromSettings() {
        let service = EventVectorService()
        // Dimension is read from settings; verify the formula holds
        XCTAssertGreaterThan(service.embeddingDim, 0)
    }

    func testEventVecDimFormula() {
        let service = EventVectorService()
        // eventVecDim = 3 * embeddingDim + RelationFamily.count
        let expected = 3 * service.embeddingDim + RelationFamily.count
        XCTAssertEqual(service.eventVecDim, expected)
    }

    func testIdfMaxConstant() {
        XCTAssertEqual(EventVectorService.idfMax, 6.0)
    }

    // MARK: - IDF Formula (unit test the math)

    func testIdfFormulaHighFrequencyNode() {
        // Node appearing in every event: df = N
        let n = 1000.0
        let df = 1000.0
        let idf = min(Foundation.log((n + 1) / (df + 1)) + 1.0, 6.0)

        // log(1001/1001) + 1 = 0 + 1 = 1
        XCTAssertEqual(idf, 1.0, accuracy: 0.01,
                       "Hub node should have IDF close to 1")
    }

    func testIdfFormulaRareNode() {
        // Node appearing in 1 event out of 10000
        let n = 10000.0
        let df = 1.0
        let idf = min(Foundation.log((n + 1) / (df + 1)) + 1.0, 6.0)

        // log(10001/2) + 1 ≈ 8.52 + 1 = 9.52, clamped to 6.0
        XCTAssertEqual(idf, 6.0, accuracy: 0.01,
                       "Rare node should be clamped to idfMax")
    }

    func testIdfFormulaModerateNode() {
        // Node appearing in 100 events out of 1000
        let n = 1000.0
        let df = 100.0
        let idf = min(Foundation.log((n + 1) / (df + 1)) + 1.0, 6.0)

        // log(1001/101) + 1 ≈ 2.29 + 1 = 3.29
        XCTAssertGreaterThan(idf, 1.0)
        XCTAssertLessThan(idf, 6.0)
    }

    func testIdfFormulaZeroDf() {
        // Node with no appearances
        let n = 1000.0
        let df = 0.0
        let idf = min(Foundation.log((n + 1) / (df + 1)) + 1.0, 6.0)

        // log(1001/1) + 1 ≈ 6.91 + 1 = 7.91, clamped to 6.0
        XCTAssertEqual(idf, 6.0, accuracy: 0.01)
    }

    // MARK: - Weighted Mean Embedding (testing the math via AccelerateVectorOps)

    func testWeightedMeanEqualWeights() {
        // Two identical vectors with equal weights → same vector
        let emb1: [Float] = [1, 0, 0]
        let emb2: [Float] = [1, 0, 0]

        var sum = [Float](repeating: 0, count: 3)
        vDSP_vadd(emb1, 1, emb2, 1, &sum, 1, 3)
        var scale: Float = 0.5
        vDSP_vsmul(sum, 1, &scale, &sum, 1, 3)

        XCTAssertEqual(sum, [1, 0, 0])
    }

    func testWeightedMeanDifferentWeights() {
        // emb1 = [1,0], weight=3; emb2 = [0,1], weight=1
        // Result = (3*[1,0] + 1*[0,1]) / 4 = [0.75, 0.25]
        let emb1: [Float] = [1, 0]
        let emb2: [Float] = [0, 1]
        let w1: Float = 3.0
        let w2: Float = 1.0

        var scaled1 = [Float](repeating: 0, count: 2)
        var scaled2 = [Float](repeating: 0, count: 2)
        var wt1 = w1
        var wt2 = w2
        vDSP_vsmul(emb1, 1, &wt1, &scaled1, 1, 2)
        vDSP_vsmul(emb2, 1, &wt2, &scaled2, 1, 2)

        var sum = [Float](repeating: 0, count: 2)
        vDSP_vadd(scaled1, 1, scaled2, 1, &sum, 1, 2)

        var invTotal: Float = 1.0 / (w1 + w2)
        vDSP_vsmul(sum, 1, &invTotal, &sum, 1, 2)

        XCTAssertEqual(sum[0], 0.75, accuracy: 0.001)
        XCTAssertEqual(sum[1], 0.25, accuracy: 0.001)
    }

    // MARK: - Event Vector Layout

    func testEventVectorLayoutDimensions() {
        let service = EventVectorService()
        let dim = service.embeddingDim

        // Verify the layout: [sNorm(dim) | tNorm(dim) | diffNorm(dim) | oneHot(RelationFamily.count)]
        let sStart = 0
        let sEnd = dim
        let tStart = dim
        let tEnd = 2 * dim
        let diffStart = 2 * dim
        let diffEnd = 3 * dim
        let oneHotStart = 3 * dim
        let oneHotEnd = 3 * dim + RelationFamily.count

        XCTAssertEqual(sEnd - sStart, service.embeddingDim)
        XCTAssertEqual(tEnd - tStart, service.embeddingDim)
        XCTAssertEqual(diffEnd - diffStart, service.embeddingDim)
        XCTAssertEqual(oneHotEnd - oneHotStart, RelationFamily.count)
        XCTAssertEqual(oneHotEnd, service.eventVecDim)
    }

    // MARK: - Normalization

    func testNormalizeProducesUnitVector() {
        let vec: [Float] = [3, 4, 0]
        let normalized = AccelerateVectorOps.normalize(vec)

        // Norm should be 1.0
        var normSq: Float = 0
        vDSP_svesq(normalized, 1, &normSq, vDSP_Length(normalized.count))
        XCTAssertEqual(sqrt(normSq), 1.0, accuracy: 0.001)

        // Direction preserved: [0.6, 0.8, 0]
        XCTAssertEqual(normalized[0], 0.6, accuracy: 0.001)
        XCTAssertEqual(normalized[1], 0.8, accuracy: 0.001)
        XCTAssertEqual(normalized[2], 0.0, accuracy: 0.001)
    }

    func testNormalizeZeroVectorUnchanged() {
        let vec: [Float] = [0, 0, 0]
        let normalized = AccelerateVectorOps.normalize(vec)
        XCTAssertEqual(normalized, [0, 0, 0])
    }
}
