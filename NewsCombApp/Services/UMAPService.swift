import Foundation
import MLX
import OSLog
import UMAPMLX

/// GPU-accelerated UMAP via MLX. Runs in-process — Conduit 1.0.4 trait-gates
/// every MLX-touching source file, so MLX visibility from this package no
/// longer leaks into Conduit's `MLXProvider` references via SwiftAgents.
///
/// The previous pure-Swift VP-tree + SGD layout was single-threaded on the CPU
/// and dominated the theme-rebuild pipeline at production scale (~tens of
/// minutes for ~116K events). MLX runs on Apple Silicon's GPU.
final class UMAPService: Sendable {

    /// Configuration parameters for UMAP. Field names mirror the upstream
    /// `UMAP.Configuration` so existing call sites and `AppSettings` keys keep
    /// working unchanged.
    struct Parameters {
        var targetDimension: Int = 25
        var nNeighbors: Int = 15
        var minDist: Float = 0.1
        /// `nil` lets UMAPMLX pick: 500 epochs if n ≤ 10K, otherwise 200.
        var nEpochs: Int? = nil
        var negativeSampleRate: Int = 5
        var learningRate: Float = 1.0
        var spread: Float = 1.0
        /// `nil` means non-deterministic; any other value seeds `MLXRandom`.
        var seed: UInt64? = 42
    }

    private let logger = Logger(subsystem: "com.newscomb", category: "UMAPService")

    /// Cap MLX's allocator cache once per process. The default `cacheLimit`
    /// equals `memoryLimit`, which on a Mac with abundant RAM grows to tens
    /// of GB and stays resident long after the GPU work that produced it has
    /// finished — putting OS-level memory pressure on subsequent CPU stages
    /// of the pipeline (the Accelerate-based HDBSCAN kNN observed mid-run
    /// per-tile slowdowns 0.6s → 21s when this cache was unconstrained).
    /// 4 GB is generous for the SGD inner loop's working set at production
    /// N (~116K) and small enough to leave the rest of the system breathable.
    private static let configureMLXMemoryOnce: Void = {
        let cap = 4 * 1024 * 1024 * 1024
        MLX.Memory.cacheLimit = cap
        Logger(subsystem: "com.newscomb", category: "UMAPService")
            .info("MLX cache limit set to \(cap) bytes")
    }()

    /// Reduces vectors to a low-dimensional embedding via MLX UMAP.
    ///
    /// - Parameters:
    ///   - vectors: Array of N vectors (typically PCA-reduced to ~50D).
    ///   - params: UMAP configuration.
    ///   - progressCallback: Optional callback invoked with
    ///     `(currentEpoch, totalEpochs)` during SGD optimization.
    /// - Returns: Array of N vectors, each of `params.targetDimension` dimensions.
    /// - Throws: `UMAPError` from the underlying library on bad input or
    ///   unrecoverable failure. Callers must surface the error so a broken
    ///   UMAP step doesn't silently feed un-reduced vectors to HDBSCAN.
    func reduce(
        vectors: [[Float]],
        params: Parameters = Parameters(),
        progressCallback: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> [[Float]] {
        _ = Self.configureMLXMemoryOnce
        let n = vectors.count
        guard n >= 2 else { return vectors }

        let inputDim = vectors[0].count
        // If the caller asks for an output dim ≥ input dim there's nothing to reduce.
        guard params.targetDimension < inputDim else {
            logger.notice("UMAP: target dim (\(params.targetDimension)) >= input dim (\(inputDim)); returning input")
            return vectors
        }
        // UMAPMLX requires nNeighbors < n; clamp to the largest valid value.
        let effectiveNeighbors = min(params.nNeighbors, n - 1)
        guard effectiveNeighbors >= 1 else { return vectors }

        logger.info("UMAP: n=\(n), inDim=\(inputDim), outDim=\(params.targetDimension), k=\(effectiveNeighbors)")
        let pipelineStart = ContinuousClock.now

        var configuration = UMAP.Configuration()
        configuration.nComponents = params.targetDimension
        configuration.nNeighbors = effectiveNeighbors
        configuration.minDist = params.minDist
        configuration.spread = params.spread
        configuration.nEpochs = params.nEpochs
        configuration.negativeSampleRate = params.negativeSampleRate
        configuration.learningRate = params.learningRate
        configuration.randomSeed = params.seed

        let result = try await Self.runUMAP(
            vectors: vectors,
            n: n,
            dIn: inputDim,
            configuration: configuration,
            progressCallback: progressCallback
        )

        let elapsed = ContinuousClock.now - pipelineStart
        logger.info("UMAP complete: \(n) points → \(params.targetDimension)D in \(elapsed)")
        return result
    }

    /// MLX work runs on the concurrent executor so the caller's actor (often
    /// `@MainActor` via `ClusteringService`) isn't blocked by GPU dispatch
    /// and `eval()` waits.
    @concurrent
    private static func runUMAP(
        vectors: [[Float]],
        n: Int,
        dIn: Int,
        configuration: UMAP.Configuration,
        progressCallback: (@Sendable (Int, Int) -> Void)?
    ) async throws -> [[Float]] {
        var flat = [Float](repeating: 0, count: n * dIn)
        flat.withUnsafeMutableBufferPointer { dst in
            for i in 0 ..< n {
                let row = vectors[i]
                let count = Swift.min(row.count, dIn)
                row.withUnsafeBufferPointer { src in
                    for j in 0 ..< count {
                        dst[i * dIn + j] = src[j]
                    }
                }
            }
        }
        let input = MLXArray(flat, [n, dIn])

        let umap = UMAP(configuration)
        let embedding = try umap.fitTransform(input, progressCallback: progressCallback)
        eval(embedding)

        let floats = embedding.asArray(Float.self)
        let outDim = configuration.nComponents
        guard floats.count == n * outDim else {
            // UMAPMLX guarantees this shape, but assert at the boundary to
            // catch any future API drift before it corrupts downstream HDBSCAN.
            throw UMAPError.dimensionMismatch(expected: n * outDim, got: floats.count)
        }

        var result: [[Float]] = []
        result.reserveCapacity(n)
        for i in 0 ..< n {
            let start = i * outDim
            result.append(Array(floats[start ..< (start + outDim)]))
        }

        // Drop GPU buffers before returning so downstream CPU stages
        // (HDBSCAN kNN, MST) don't compete with our temporaries for the
        // OS memory budget. eval(embedding) above already blocked until
        // GPU work finished and asArray copied the data to host memory,
        // so it's safe to clear MLX's allocator cache now. cacheLimit
        // alone only takes effect on the *next* deallocation per the
        // MLX docstring, so we explicitly clear here.
        let logger = Logger(subsystem: "com.newscomb", category: "UMAPService")
        let before = MLX.Memory.snapshot()
        MLX.Memory.clearCache()
        let after = MLX.Memory.snapshot()
        logger.info(
            "MLX memory after UMAP: active \(before.activeMemory)→\(after.activeMemory) bytes, cache \(before.cacheMemory)→\(after.cacheMemory) bytes (peak \(after.peakMemory))"
        )

        return result
    }
}
