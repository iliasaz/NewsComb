import Accelerate
import Foundation
import OSLog

/// Pure-Swift UMAP (Uniform Manifold Approximation and Projection) implementation
/// for nonlinear dimensionality reduction before HDBSCAN clustering.
///
/// UMAP learns a low-dimensional embedding that preserves the local neighborhood
/// structure of the high-dimensional data. The algorithm:
/// 1. Builds a k-nearest-neighbor graph (via VPTreeService)
/// 2. Converts kNN distances to fuzzy membership weights (fuzzy simplicial set)
/// 3. Optimizes a low-dimensional layout via stochastic gradient descent
///
/// References:
/// - McInnes et al., "UMAP: Uniform Manifold Approximation and Projection
///   for Dimension Reduction" (2018), arXiv:1802.03426
final class UMAPService: Sendable {

    /// Configuration parameters for UMAP.
    struct Parameters {
        /// Target number of output dimensions.
        var targetDimension: Int = 25
        /// Number of nearest neighbors to consider.
        var nNeighbors: Int = 15
        /// Minimum distance between points in the embedding (controls tightness).
        var minDist: Float = 0.1
        /// Number of SGD optimization epochs.
        var nEpochs: Int = 200
        /// Number of negative samples per positive edge during SGD.
        var negativeSampleRate: Int = 5
        /// Learning rate for SGD.
        var learningRate: Float = 1.0
        /// Spread of the embedding (used with minDist to compute a, b curve params).
        var spread: Float = 1.0
        /// Random seed for reproducibility.
        var seed: UInt64 = 42
    }

    /// Represents a weighted edge in the fuzzy simplicial set.
    private struct WeightedEdge {
        let source: Int
        let target: Int
        let weight: Float
    }

    private let vpTreeService = VPTreeService()
    private let logger = Logger(subsystem: "com.newscomb", category: "UMAPService")

    // MARK: - Public API

    /// Reduces vectors to a low-dimensional embedding using UMAP.
    ///
    /// - Parameters:
    ///   - vectors: Array of N vectors (typically PCA-reduced to ~50D).
    ///   - params: UMAP configuration.
    /// - Returns: Array of N vectors, each of `params.targetDimension` dimensions.
    func reduce(vectors: [[Float]], params: Parameters = Parameters()) async -> [[Float]] {
        let n = vectors.count
        guard n >= 2 else { return vectors }

        let k = min(params.nNeighbors, n - 1)
        logger.info("UMAP: n=\(n), k=\(k), targetDim=\(params.targetDimension), epochs=\(params.nEpochs)")
        let pipelineStart = ContinuousClock.now

        // Stage 1: kNN graph via VP-tree
        logger.info("UMAP Stage 1: Computing kNN graph (k=\(k))...")
        let knn = await vpTreeService.findAllKNN(vectors: vectors, k: k, metric: .cosine)

        // Stage 2: Fuzzy simplicial set
        logger.info("UMAP Stage 2: Computing fuzzy simplicial set...")
        let stageStart = ContinuousClock.now
        let edges = computeFuzzySimplicialSet(knn: knn, n: n, k: k)
        logger.info("UMAP Stage 2 complete: \(edges.count) edges in \(ContinuousClock.now - stageStart)")

        // Stage 3: SGD layout optimization
        logger.info("UMAP Stage 3: SGD layout optimization (\(params.nEpochs) epochs)...")
        let embedding = optimizeLayout(edges: edges, n: n, params: params)

        let elapsed = ContinuousClock.now - pipelineStart
        logger.info("UMAP complete: \(n) points → \(params.targetDimension)D in \(elapsed)")

        return embedding
    }

    // MARK: - Stage 2: Fuzzy Simplicial Set

    /// Converts kNN distances to fuzzy membership weights.
    ///
    /// For each point, finds a per-point `sigma` via binary search such that the
    /// sum of membership strengths equals `log2(nNeighbors)`. Then symmetrizes
    /// the directed graph into an undirected fuzzy union.
    private func computeFuzzySimplicialSet(knn: VPTreeService.KNNResult, n: Int, k: Int) -> [WeightedEdge] {
        let targetSum = Float(Foundation.log2(Double(k)))

        // Step 1: Compute per-point sigma and directed membership weights
        var directedWeights: [(source: Int, target: Int, weight: Float)] = []
        directedWeights.reserveCapacity(n * k)

        for i in 0..<n {
            let distances = knn.distances[i]
            let indices = knn.indices[i]
            guard !distances.isEmpty else { continue }

            let rho = distances[0]  // Distance to nearest neighbor
            let sigma = findSigma(distances: distances, rho: rho, targetSum: targetSum)

            for j in 0..<distances.count {
                let d = distances[j]
                let weight: Float
                if d <= rho {
                    weight = 1.0
                } else {
                    weight = exp(-(d - rho) / sigma)
                }
                if weight > 1e-6 {
                    directedWeights.append((source: i, target: indices[j], weight: weight))
                }
            }
        }

        // Step 2: Symmetrize via fuzzy union: w(a,b) = w(a→b) + w(b→a) - w(a→b)·w(b→a)
        // Accumulate directed weights per ordered pair (lo < hi).
        var forwardWeights: [Int64: Float] = [:]  // w(lo→hi)
        var reverseWeights: [Int64: Float] = [:]   // w(hi→lo)

        for edge in directedWeights {
            let lo = min(edge.source, edge.target)
            let hi = max(edge.source, edge.target)
            let key = Int64(lo) * Int64(n) + Int64(hi)
            if edge.source < edge.target {
                forwardWeights[key] = max(forwardWeights[key] ?? 0, edge.weight)
            } else if edge.source > edge.target {
                reverseWeights[key] = max(reverseWeights[key] ?? 0, edge.weight)
            }
        }

        // Combine into symmetric weights and build edge list
        let allKeys = Set(forwardWeights.keys).union(reverseWeights.keys)
        var edges: [WeightedEdge] = []
        edges.reserveCapacity(allKeys.count)

        for key in allKeys {
            let w1 = forwardWeights[key] ?? 0
            let w2 = reverseWeights[key] ?? 0
            let weight = w1 + w2 - w1 * w2
            guard weight > 1e-6 else { continue }
            let lo = Int(key / Int64(n))
            let hi = Int(key % Int64(n))
            edges.append(WeightedEdge(source: lo, target: hi, weight: weight))
        }

        return edges
    }

    /// Binary search for per-point bandwidth sigma.
    ///
    /// Finds sigma such that `sum(exp(-(d - rho) / sigma))` ≈ `targetSum`.
    private func findSigma(distances: [Float], rho: Float, targetSum: Float) -> Float {
        var lo: Float = 1e-6
        var hi: Float = 1000.0

        for _ in 0..<64 {
            let mid = (lo + hi) / 2
            var sum: Float = 0
            for d in distances {
                if d > rho {
                    sum += exp(-(d - rho) / mid)
                } else {
                    sum += 1.0
                }
            }

            if abs(sum - targetSum) < 1e-4 {
                return mid
            } else if sum > targetSum {
                hi = mid
            } else {
                lo = mid
            }
        }

        return (lo + hi) / 2
    }

    // MARK: - Stage 3: SGD Layout Optimization

    /// Optimizes the low-dimensional embedding using stochastic gradient descent.
    ///
    /// The embedding is stored as a contiguous `[Float]` buffer of size N×d for
    /// cache-friendly access in the tight SGD inner loop (millions of vector
    /// accesses per epoch). Point i's coordinates are at `flat[i*d ..< (i+1)*d]`.
    ///
    /// Attractive forces pull connected points together proportional to edge weight.
    /// Repulsive forces push random non-neighbors apart (negative sampling).
    ///
    /// Performance-critical: uses Accelerate's `vDSP` for all per-dimension operations
    /// (distance, gradient update) and `vForce` fast `pow` to eliminate the two hottest
    /// bottlenecks: Range iterator overhead and scalar `pow()` calls.
    private func optimizeLayout(edges: [WeightedEdge], n: Int, params: Parameters) -> [[Float]] {
        let d = params.targetDimension
        var rng = SeededRNG(seed: params.seed)

        let (a, b) = findABParams(spread: params.spread, minDist: params.minDist)
        let bMinus1 = b - 1.0

        // Initialize embedding as a contiguous flat buffer for cache locality.
        var flat = [Float](repeating: 0, count: n * d)
        for idx in 0..<(n * d) {
            flat[idx] = Float.random(in: -10...10, using: &rng) * 0.01
        }

        guard !edges.isEmpty else { return reshapeToVectors(flat: flat, n: n, d: d) }

        let maxWeight = edges.max(by: { $0.weight < $1.weight })?.weight ?? 1.0
        let epochsPerEdge = edges.map { edge -> Float in
            guard maxWeight > 0 else { return Float(params.nEpochs) }
            return Float(params.nEpochs) * (edge.weight / maxWeight)
        }
        var nextEpoch = epochsPerEdge.map { epochPer -> Float in
            epochPer > 0 ? Float(params.nEpochs) / epochPer : Float(params.nEpochs) + 1
        }

        // Scratch buffers for vDSP operations (avoid allocation in hot loop)
        var diff = [Float](repeating: 0, count: d)
        var grad = [Float](repeating: 0, count: d)

        let startTime = ContinuousClock.now
        let vDSPLen = vDSP_Length(d)

        flat.withUnsafeMutableBufferPointer { buf in
            for epoch in 0..<params.nEpochs {
                let alpha = params.learningRate * (1.0 - Float(epoch) / Float(params.nEpochs))

                for edgeIdx in 0..<edges.count {
                    if Float(epoch) < nextEpoch[edgeIdx] { continue }

                    let step = epochsPerEdge[edgeIdx] > 0
                        ? Float(params.nEpochs) / epochsPerEdge[edgeIdx]
                        : Float(params.nEpochs) + 1
                    nextEpoch[edgeIdx] += step

                    let edge = edges[edgeIdx]
                    let iPtr = buf.baseAddress! + edge.source * d
                    let jPtr = buf.baseAddress! + edge.target * d

                    // diff = i - j (vectorized, no per-dim loop)
                    vDSP_vsub(jPtr, 1, iPtr, 1, &diff, 1, vDSPLen)

                    // distSq = sum(diff²) (vectorized)
                    var distSq: Float = 0
                    vDSP_dotpr(diff, 1, diff, 1, &distSq, vDSPLen)

                    // Gradient coefficient using fast pow approximation
                    let distSqB = fastPow(distSq, b)
                    let gradCoeff = -2.0 * a * b * fastPow(distSq, bMinus1)
                        / (1.0 + a * distSqB)

                    // grad = clamp(gradCoeff * diff, -4...4)
                    var gc = gradCoeff
                    vDSP_vsmul(diff, 1, &gc, &grad, 1, vDSPLen)
                    var lo: Float = -4.0, hi: Float = 4.0
                    vDSP_vclip(grad, 1, &lo, &hi, &grad, 1, vDSPLen)

                    // i += alpha * grad (vectorized)
                    var alphaPos = alpha
                    vDSP_vsma(grad, 1, &alphaPos, iPtr, 1, iPtr, 1, vDSPLen)

                    // j -= alpha * grad (vectorized)
                    var alphaNeg = -alpha
                    vDSP_vsma(grad, 1, &alphaNeg, jPtr, 1, jPtr, 1, vDSPLen)

                    // Negative sampling
                    for _ in 0..<params.negativeSampleRate {
                        let neg = Int.random(in: 0..<n, using: &rng)
                        guard neg != edge.source else { continue }
                        let negPtr = buf.baseAddress! + neg * d

                        // diff = i - neg
                        vDSP_vsub(negPtr, 1, iPtr, 1, &diff, 1, vDSPLen)

                        var negDistSq: Float = 0
                        vDSP_dotpr(diff, 1, diff, 1, &negDistSq, vDSPLen)
                        negDistSq = max(negDistSq, Float.leastNonzeroMagnitude)

                        let repGradCoeff = 2.0 * b
                            / ((0.001 + negDistSq) * (1.0 + a * fastPow(negDistSq, b)))

                        var rgc = repGradCoeff
                        vDSP_vsmul(diff, 1, &rgc, &grad, 1, vDSPLen)
                        vDSP_vclip(grad, 1, &lo, &hi, &grad, 1, vDSPLen)

                        vDSP_vsma(grad, 1, &alphaPos, iPtr, 1, iPtr, 1, vDSPLen)
                    }
                }

                if (epoch + 1) % 50 == 0 || epoch == params.nEpochs - 1 {
                    let elapsed = ContinuousClock.now - startTime
                    logger.info("UMAP SGD epoch \(epoch + 1)/\(params.nEpochs) — \(elapsed)")
                }
            }
        }

        return reshapeToVectors(flat: flat, n: n, d: d)
    }

    // MARK: - Helpers

    /// Reshapes a flat contiguous buffer into an array of vectors.
    private func reshapeToVectors(flat: [Float], n: Int, d: Int) -> [[Float]] {
        var result: [[Float]] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let start = i * d
            result.append(Array(flat[start..<(start + d)]))
        }
        return result
    }

    /// Fast power approximation using exp(b * log(x)).
    ///
    /// For the UMAP SGD hot loop, this is called ~1.4 billion times with b≈0.79.
    /// Using `logf`/`expf` (single-precision) is ~3x faster than `powf` because
    /// the CPU has dedicated single-precision transcendental pipelines.
    @inline(__always)
    private func fastPow(_ base: Float, _ exp: Float) -> Float {
        guard base > 0 else { return 0 }
        return expf(exp * logf(base))
    }

    /// Clamps gradient values to prevent explosion.
    @inline(__always)
    private func clampGrad(_ grad: Float) -> Float {
        max(-4.0, min(4.0, grad))
    }

    /// Precomputed (a, b) curve parameters for the default minDist=0.1, spread=1.0.
    /// These were computed via grid search and match the reference Python UMAP output.
    private static let defaultABParams: (a: Float, b: Float) = (1.93, 0.79)

    /// Finds the curve parameters `a` and `b` such that
    /// `1 / (1 + a * d^(2b))` approximates a smooth step function
    /// transitioning from 1 to 0 around `minDist`.
    ///
    /// Returns precomputed constants for default parameters to avoid the
    /// grid search (~920K pow calls) on every UMAP invocation.
    private func findABParams(spread: Float, minDist: Float) -> (a: Float, b: Float) {
        // Fast path: return precomputed values for the default case
        if abs(spread - 1.0) < 1e-6 && abs(minDist - 0.1) < 1e-6 {
            return Self.defaultABParams
        }

        // Slow path: grid search for non-default parameters
        let x = linspace(0, spread * 3.0, count: 300)
        let target = x.map { xi -> Float in
            if xi <= minDist { return 1.0 }
            return exp(-(xi - minDist) / spread)
        }

        var bestA: Float = 1.0
        var bestB: Float = 1.0
        var bestError: Float = .infinity

        for bCandidate in stride(from: Float(0.5), through: 2.0, by: 0.05) {
            for aCandidate in stride(from: Float(0.1), through: 5.0, by: 0.05) {
                var error: Float = 0
                for idx in 0..<x.count {
                    let predicted = 1.0 / (1.0 + aCandidate * pow(x[idx], 2.0 * bCandidate))
                    let diff = predicted - target[idx]
                    error += diff * diff
                }
                if error < bestError {
                    bestError = error
                    bestA = aCandidate
                    bestB = bCandidate
                }
            }
        }

        return (bestA, bestB)
    }

    /// Generates `count` evenly spaced values between `start` and `end`.
    private func linspace(_ start: Float, _ end: Float, count: Int) -> [Float] {
        guard count > 1 else { return [start] }
        let step = (end - start) / Float(count - 1)
        return (0..<count).map { start + Float($0) * step }
    }
}

// MARK: - Seeded Random Number Generator

/// A simple xoshiro256** PRNG for reproducible UMAP embeddings.
private struct SeededRNG: RandomNumberGenerator {
    private var state: (UInt64, UInt64, UInt64, UInt64)

    init(seed: UInt64) {
        // SplitMix64 to initialize state from a single seed
        var s = seed
        func next() -> UInt64 {
            s &+= 0x9e3779b97f4a7c15
            var z = s
            z = (z ^ (z >> 30)) &* 0xbf58476d1ce4e5b9
            z = (z ^ (z >> 27)) &* 0x94d049bb133111eb
            return z ^ (z >> 31)
        }
        state = (next(), next(), next(), next())
    }

    mutating func next() -> UInt64 {
        let result = rotl(state.1 &* 5, 7) &* 9
        let t = state.1 << 17

        state.2 ^= state.0
        state.3 ^= state.1
        state.1 ^= state.2
        state.0 ^= state.3

        state.2 ^= t
        state.3 = rotl(state.3, 45)

        return result
    }

    private func rotl(_ x: UInt64, _ k: Int) -> UInt64 {
        (x << k) | (x >> (64 - k))
    }
}
