import Accelerate
import OSLog

/// Optimized vector operations using Apple's Accelerate framework.
/// Used for efficient cosine similarity and similarity matrix computations.
struct AccelerateVectorOps {

    /// A pair of vector indices and their similarity score. Nominal struct
    /// rather than a labeled tuple so callers avoid the runtime tuple-metadata
    /// cache lookups that showed up as hot frames in profiling.
    struct SimilarPair: Sendable, Equatable {
        let i: Int
        let j: Int
        let similarity: Float
    }

    private static let logger = Logger(subsystem: "com.newscomb", category: "AccelerateVectorOps")

    /// Cosine similarity between two vectors using vDSP.
    /// Returns a value between -1 and 1, where 1 means identical direction.
    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vectors must have the same dimension")
        guard !a.isEmpty else { return 0 }

        let n = vDSP_Length(a.count)

        var dotProduct: Float = 0
        var normASq: Float = 0
        var normBSq: Float = 0

        // Dot product: a · b
        vDSP_dotpr(a, 1, b, 1, &dotProduct, n)

        // Sum of squares: ||a||², ||b||²
        vDSP_svesq(a, 1, &normASq, n)
        vDSP_svesq(b, 1, &normBSq, n)

        let denominator = sqrt(normASq) * sqrt(normBSq)
        return denominator > 0 ? dotProduct / denominator : 0
    }

    /// Build NxN cosine similarity matrix using BLAS matrix multiplication.
    /// For N vectors of dimension D, this computes all pairwise similarities efficiently.
    ///
    /// - Parameter embeddings: Array of N embedding vectors, each of dimension D
    /// - Returns: NxN matrix where element [i][j] is the cosine similarity between vectors i and j
    static func cosineSimilarityMatrix(_ embeddings: [[Float]]) -> [[Float]] {
        guard !embeddings.isEmpty else { return [] }
        guard let dim = embeddings.first?.count, dim > 0 else { return [] }

        let n = embeddings.count

        // Flatten and normalize embeddings
        var normalized = [Float](repeating: 0, count: n * dim)

        for i in 0..<n {
            let embedding = embeddings[i]
            guard embedding.count == dim else { continue }

            // Compute norm
            var normSq: Float = 0
            vDSP_svesq(embedding, 1, &normSq, vDSP_Length(dim))
            let norm = sqrt(normSq)

            if norm > 0 {
                // Normalize and copy to flat array
                var scale = 1.0 / norm
                var normalizedRow = [Float](repeating: 0, count: dim)
                vDSP_vsmul(embedding, 1, &scale, &normalizedRow, 1, vDSP_Length(dim))
                normalized.replaceSubrange((i * dim)..<((i + 1) * dim), with: normalizedRow)
            }
        }

        // Matrix multiply: A * Aᵀ = similarity matrix
        // For normalized vectors, dot product equals cosine similarity.
        // Use vDSP_mmul (non-deprecated) with an explicit transpose.
        var transposed = [Float](repeating: 0, count: dim * n)
        vDSP_mtrans(normalized, 1, &transposed, 1, vDSP_Length(dim), vDSP_Length(n))

        var result = [Float](repeating: 0, count: n * n)
        vDSP_mmul(
            normalized, 1,      // A: n × dim
            transposed, 1,      // Aᵀ: dim × n
            &result, 1,         // C: n × n
            vDSP_Length(n),     // M: rows of A
            vDSP_Length(n),     // N: cols of Aᵀ
            vDSP_Length(dim)    // P: cols of A / rows of Aᵀ
        )

        // Reshape to 2D array
        return stride(from: 0, to: n * n, by: n).map { start in
            Array(result[start..<(start + n)])
        }
    }

    /// Find top-k most similar vectors to a query vector.
    ///
    /// - Parameters:
    ///   - query: The query embedding vector
    ///   - embeddings: Array of embedding vectors to search
    ///   - k: Number of top results to return
    /// - Returns: Array of (index, similarity) tuples, sorted by similarity descending
    static func topKSimilar(
        query: [Float],
        embeddings: [[Float]],
        k: Int
    ) -> [(index: Int, similarity: Float)] {
        guard !embeddings.isEmpty else { return [] }

        let similarities = embeddings.enumerated().map { (idx, emb) in
            (index: idx, similarity: cosineSimilarity(query, emb))
        }

        return similarities
            .sorted { $0.similarity > $1.similarity }
            .prefix(k)
            .map { $0 }
    }

    /// Find all pairs of vectors with similarity above a threshold.
    /// Only returns pairs where i < j to avoid duplicates.
    ///
    /// Uses a blocked matrix multiply (BLAS `cblas_sgemm`) so memory is
    /// O(blockSize · N) instead of O(N²). For N = 143k that's ~1.2 GB at
    /// blockSize = 2048 versus ~82 GB for the full similarity matrix.
    ///
    /// `cblas_sgemm` is the Accelerate BLAS path that uses the AMX coprocessor
    /// and is internally multi-threaded — typically 50–100× faster than
    /// `vDSP_mmul` for sizes like these on Apple Silicon. Passing `CblasTrans`
    /// for B avoids a pre-transposed copy of the normalized matrix.
    ///
    /// - Parameters:
    ///   - embeddings: Array of embedding vectors (must share dimension)
    ///   - threshold: Minimum similarity to include (default 0.9)
    ///   - blockSize: Number of rows processed per sgemm call. Larger values
    ///     improve throughput; smaller values reduce peak RAM. The default of
    ///     2048 is a good balance on Apple Silicon.
    /// - Returns: Array of (index1, index2, similarity) tuples, sorted by
    ///   similarity descending.
    static func findSimilarPairs(
        embeddings: [[Float]],
        threshold: Float = 0.9,
        blockSize: Int = 2048
    ) -> [SimilarPair] {
        let n = embeddings.count
        guard n > 1 else { return [] }
        guard let dim = embeddings.first?.count, dim > 0 else { return [] }
        let block = max(1, min(blockSize, n))
        let totalBlocks = (n + block - 1) / block

        let startTime = ContinuousClock.now
        logger.info("findSimilarPairs: n=\(n), dim=\(dim), block=\(block), blocks=\(totalBlocks), threshold=\(threshold)")

        // 1. Normalize all embeddings into a flat row-major buffer.
        //    Memory: n * dim * 4 bytes (e.g. ~220 MB for 143k × 384).
        var normalized = [Float](repeating: 0, count: n * dim)
        normalized.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                let embedding = embeddings[i]
                guard embedding.count == dim else { continue }
                var normSq: Float = 0
                vDSP_svesq(embedding, 1, &normSq, vDSP_Length(dim))
                let norm = sqrt(normSq)
                guard norm > 0 else { continue }
                var scale: Float = 1.0 / norm
                let dest = buf.baseAddress!.advanced(by: i * dim)
                vDSP_vsmul(embedding, 1, &scale, dest, 1, vDSP_Length(dim))
            }
        }

        logger.info("findSimilarPairs: normalized in \(ContinuousClock.now - startTime)")

        // 2. Block scratch: one reused buffer for each row stripe.
        //    Memory: block * n * 4 bytes (e.g. ~1.2 GB for 2048 × 143k).
        var blockResult = [Float](repeating: 0, count: block * n)
        var pairs: [SimilarPair] = []
        // Reserve a modest capacity so the early geometric-growth reallocations
        // (which showed up as malloc/memmove hot frames) don't fire.
        pairs.reserveCapacity(4096)

        // Log progress at most ~20 times across the run so we get visible
        // movement without flooding the log for huge graphs.
        let logEvery = max(1, totalBlocks / 20)
        var blockIndex = 0
        var rowStart = 0
        while rowStart < n {
            let rows = min(block, n - rowStart)

            // C (rows × n) = A_block (rows × dim) × normalizedᵀ (dim × n)
            // Using cblas_sgemm with TransB lets us multiply by Aᵀ on the fly
            // — no separately materialized transposed buffer needed.
            normalized.withUnsafeBufferPointer { normPtr in
                blockResult.withUnsafeMutableBufferPointer { resPtr in
                    let aBlock = normPtr.baseAddress!.advanced(by: rowStart * dim)
                    cblas_sgemm(
                        CblasRowMajor,
                        CblasNoTrans,            // A: rows × dim
                        CblasTrans,              // B: n × dim, used as dim × n
                        rows,                    // M
                        n,                       // N
                        dim,                     // K
                        1.0,                     // alpha
                        aBlock, dim,             // A, lda
                        normPtr.baseAddress!, dim,  // B, ldb (full normalized)
                        0.0,                     // beta
                        resPtr.baseAddress!, n   // C, ldc
                    )
                }
            }

            // Scan upper triangle within this block: j must be > globalI.
            // Tight raw-pointer + `while` loop on purpose — Range iteration
            // (IndexingIterator / formIndex / bounds checks) was the top
            // user-code hot path in profiling.
            blockResult.withUnsafeBufferPointer { res in
                let base = res.baseAddress!
                var localI = 0
                while localI < rows {
                    let globalI = rowStart + localI
                    let jStart = globalI + 1
                    if jStart < n {
                        let rowBase = base + localI * n
                        var j = jStart
                        while j < n {
                            let sim = rowBase[j]
                            if sim > threshold {
                                pairs.append(SimilarPair(i: globalI, j: j, similarity: sim))
                            }
                            j &+= 1
                        }
                    }
                    localI &+= 1
                }
            }

            rowStart += rows
            blockIndex += 1

            if blockIndex == totalBlocks || blockIndex % logEvery == 0 {
                let elapsed = ContinuousClock.now - startTime
                logger.info("findSimilarPairs: block \(blockIndex)/\(totalBlocks) — \(pairs.count) pairs so far, elapsed \(elapsed)")
            }
        }

        let totalElapsed = ContinuousClock.now - startTime
        logger.info("findSimilarPairs: done in \(totalElapsed) — \(pairs.count) pairs above threshold \(threshold), sorting")
        let sorted = pairs.sorted { $0.similarity > $1.similarity }
        logger.info("findSimilarPairs: returning \(sorted.count) sorted pairs (total elapsed \(ContinuousClock.now - startTime))")
        return sorted
    }

    /// Compute the L2 (Euclidean) distance between two vectors.
    static func l2Distance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vectors must have the same dimension")
        guard !a.isEmpty else { return 0 }

        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))

        var sumSq: Float = 0
        vDSP_svesq(diff, 1, &sumSq, vDSP_Length(diff.count))

        return sqrt(sumSq)
    }

    /// Normalize a vector to unit length.
    static func normalize(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return [] }

        var normSq: Float = 0
        vDSP_svesq(vector, 1, &normSq, vDSP_Length(vector.count))
        let norm = sqrt(normSq)

        guard norm > 0 else { return vector }

        var scale = 1.0 / norm
        var result = [Float](repeating: 0, count: vector.count)
        vDSP_vsmul(vector, 1, &scale, &result, 1, vDSP_Length(vector.count))

        return result
    }
}
