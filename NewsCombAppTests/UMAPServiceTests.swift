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

    // MARK: - Output Dimensions

    func testOutputDimension() async throws {
        // 30 vectors of 10 dimensions → reduce to 3D
        var vectors: [[Float]] = []
        for i in 0..<30 {
            vectors.append((0..<10).map { Float(i * 10 + $0) * 0.01 })
        }

        let params = UMAPService.Parameters(
            targetDimension: 3,
            nNeighbors: 5,
            nEpochs: 50  // Fewer epochs for test speed
        )
        let result = try await service.reduce(vectors: vectors, params: params)

        XCTAssertEqual(result.count, 30, "Should return same number of vectors")
        for vec in result {
            XCTAssertEqual(vec.count, 3, "Each vector should have target dimension")
        }
    }

    // MARK: - Cluster Separation

    func testClustersSeparated() async throws {
        // Two well-separated clusters of normalized vectors (different directions)
        var vectors: [[Float]] = []

        // Cluster A: pointing roughly in [1,1,0,0,0] direction
        for _ in 0..<15 {
            let noise = (0..<5).map { _ in Float.random(in: -0.05...0.05) }
            var v: [Float] = [1.0 + noise[0], 1.0 + noise[1], noise[2], noise[3], noise[4]]
            let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
            v = v.map { $0 / norm }
            vectors.append(v)
        }

        // Cluster B: pointing roughly in [0,0,1,1,0] direction
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

        // Compute mean position of each cluster in the embedding
        let meanA = meanVector(Array(result[0..<15]))
        let meanB = meanVector(Array(result[15..<30]))

        // Mean positions should be different (clusters separated)
        let dist = euclideanDistance(meanA, meanB)
        XCTAssertGreaterThan(dist, 0.1,
                             "Cluster centroids should be separated in the UMAP embedding")
    }

    // MARK: - Determinism

    func testNeighborhoodPreservation() async throws {
        // Verify that UMAP preserves local structure: points that are nearest neighbors
        // in the input should remain relatively close in the output embedding.
        var vectors: [[Float]] = []
        // Create two distinct clusters
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

        // Within-cluster distances should generally be smaller than between-cluster
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
        // 5 vectors but requesting 10 neighbors → should clamp to 4
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

    func testTargetDimensionGreaterOrEqualToInputReturnsInput() async throws {
        // 4 vectors of 3 dims; ask to "reduce" to 3D — short-circuits, no bridge call.
        let vectors: [[Float]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9], [10, 11, 12]]
        let params = UMAPService.Parameters(targetDimension: 3, nNeighbors: 2)
        let result = try await service.reduce(vectors: vectors, params: params)
        XCTAssertEqual(result, vectors)
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

// MARK: - Bridge wire-format tests
//
// These exercise UMAPService.encodeRequest / decodeResponse directly, without
// spawning the helper subprocess. They guarantee that any future change to the
// wire protocol is caught even when the bridge binary itself isn't available
// (e.g., on an unbuilt host or during a quick local check).

final class UMAPServiceBridgeFormatTests: XCTestCase {

    private let defaultParams = UMAPService.Parameters(
        targetDimension: 2,
        nNeighbors: 3,
        minDist: 0.1,
        nEpochs: 50,
        negativeSampleRate: 5,
        learningRate: 1.0,
        spread: 1.0,
        seed: 42
    )

    // MARK: encodeRequest

    func testEncodeRequestStartsWithMagic() {
        let vectors: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let data = UMAPService.encodeRequest(
            vectors: vectors, n: 2, dIn: 3, dOut: 2, nNeighbors: 1, params: defaultParams
        )
        XCTAssertEqual(data.prefix(8), Data("UMAPRQ01".utf8))
    }

    func testEncodeRequestHeaderLengthAndPayload() {
        let vectors: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let data = UMAPService.encodeRequest(
            vectors: vectors, n: 2, dIn: 3, dOut: 2, nNeighbors: 1, params: defaultParams
        )
        // 8 bytes magic + 4*Int32 dims + 2*Float + Int32 epochs + Int32 negSample + Float lr + UInt64 seed
        // = 8 + 16 + 8 + 4 + 4 + 4 + 8 = 52 bytes header, then 2*3*4 = 24 bytes payload.
        XCTAssertEqual(data.count, 52 + 24)
    }

    func testEncodeRequestRoundTripsDimensions() {
        let vectors: [[Float]] = [[1, 2, 3], [4, 5, 6], [7, 8, 9]]
        let data = UMAPService.encodeRequest(
            vectors: vectors, n: 3, dIn: 3, dOut: 2, nNeighbors: 2, params: defaultParams
        )
        // Read back the four Int32 dimension fields immediately after the magic.
        let n: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 8, as: Int32.self) }
        let dIn: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 12, as: Int32.self) }
        let dOut: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 16, as: Int32.self) }
        let nNeighbors: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 20, as: Int32.self) }
        XCTAssertEqual(n, 3)
        XCTAssertEqual(dIn, 3)
        XCTAssertEqual(dOut, 2)
        XCTAssertEqual(nNeighbors, 2)
    }

    func testEncodeRequestSerializesNilEpochsAsZero() {
        // The bridge treats `nEpochs == 0` as "auto-pick"; reduce() passes
        // params.nEpochs ?? 0, so a Parameters with nil epochs must encode 0.
        var p = defaultParams
        p.nEpochs = nil
        let data = UMAPService.encodeRequest(
            vectors: [[1, 2, 3]], n: 1, dIn: 3, dOut: 2, nNeighbors: 1, params: p
        )
        let epochs: Int32 = data.withUnsafeBytes { $0.load(fromByteOffset: 32, as: Int32.self) }
        XCTAssertEqual(epochs, 0, "nil nEpochs must serialize as 0 (auto)")
    }

    // MARK: decodeResponse

    func testDecodeResponseRejectsShortData() {
        XCTAssertThrowsError(try UMAPService.decodeResponse(Data([0, 1, 2]), expectedN: 1, expectedDOut: 1)) { err in
            guard case UMAPService.BridgeError.malformedResponse(let why) = err else {
                XCTFail("unexpected error: \(err)")
                return
            }
            XCTAssertTrue(why.contains("too short"))
        }
    }

    func testDecodeResponseRejectsBadMagic() {
        // 8 bytes of wrong magic + 8 bytes of dims = 16 bytes total
        var bytes = Array("BADMAGIC".utf8)
        bytes.append(contentsOf: [0, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertThrowsError(try UMAPService.decodeResponse(Data(bytes), expectedN: 0, expectedDOut: 0)) { err in
            guard case UMAPService.BridgeError.malformedResponse(let why) = err else {
                XCTFail("unexpected error: \(err)")
                return
            }
            XCTAssertTrue(why.contains("bad magic"))
        }
    }

    func testDecodeResponseRejectsShapeMismatch() {
        let response = makeResponse(n: 2, dOut: 3, payload: [Float](repeating: 0, count: 6))
        XCTAssertThrowsError(try UMAPService.decodeResponse(response, expectedN: 5, expectedDOut: 3)) { err in
            guard case UMAPService.BridgeError.malformedResponse(let why) = err else {
                XCTFail("unexpected error: \(err)")
                return
            }
            XCTAssertTrue(why.contains("shape mismatch"))
        }
    }

    func testDecodeResponseRejectsPayloadLengthMismatch() {
        // Header claims 2x3 = 6 floats (24 bytes), only supply 12 bytes.
        var bytes = Array("UMAPRS01".utf8)
        var n: Int32 = 2
        var d: Int32 = 3
        bytes.append(contentsOf: withUnsafeBytes(of: &n, Array.init))
        bytes.append(contentsOf: withUnsafeBytes(of: &d, Array.init))
        bytes.append(contentsOf: [UInt8](repeating: 0, count: 12))
        XCTAssertThrowsError(try UMAPService.decodeResponse(Data(bytes), expectedN: 2, expectedDOut: 3)) { err in
            guard case UMAPService.BridgeError.malformedResponse(let why) = err else {
                XCTFail("unexpected error: \(err)")
                return
            }
            XCTAssertTrue(why.contains("payload length"))
        }
    }

    func testDecodeResponseAcceptsValidPayload() throws {
        let payload: [Float] = [1, 2, 3, 4, 5, 6]
        let response = makeResponse(n: 2, dOut: 3, payload: payload)
        let result = try UMAPService.decodeResponse(response, expectedN: 2, expectedDOut: 3)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0], [1, 2, 3])
        XCTAssertEqual(result[1], [4, 5, 6])
    }

    // MARK: Helpers

    /// Builds a well-formed response frame: 8-byte magic + n + dOut + payload floats.
    private func makeResponse(n: Int32, dOut: Int32, payload: [Float]) -> Data {
        var data = Data()
        data.append(contentsOf: Array("UMAPRS01".utf8))
        var nVal = n
        var dVal = dOut
        withUnsafeBytes(of: &nVal) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dVal) { data.append(contentsOf: $0) }
        payload.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            data.append(contentsOf: UnsafeRawBufferPointer(start: base, count: buf.count * MemoryLayout<Float>.size))
        }
        return data
    }
}
