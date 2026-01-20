import Accelerate

/// Optimized vector operations using Apple's Accelerate framework.
/// Used for efficient cosine similarity and similarity matrix computations.
struct AccelerateVectorOps {

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

        // Matrix multiply: A * A^T = similarity matrix
        // For normalized vectors, dot product equals cosine similarity
        var result = [Float](repeating: 0, count: n * n)
        cblas_sgemm(
            CblasRowMajor,
            CblasNoTrans,
            CblasTrans,
            Int32(n),           // M: rows of A
            Int32(n),           // N: cols of B^T (rows of B)
            Int32(dim),         // K: cols of A (rows of B)
            1.0,                // alpha
            normalized,         // A
            Int32(dim),         // lda
            normalized,         // B
            Int32(dim),         // ldb
            0.0,                // beta
            &result,            // C
            Int32(n)            // ldc
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
    /// - Parameters:
    ///   - embeddings: Array of embedding vectors
    ///   - threshold: Minimum similarity to include (default 0.9)
    /// - Returns: Array of (index1, index2, similarity) tuples
    static func findSimilarPairs(
        embeddings: [[Float]],
        threshold: Float = 0.9
    ) -> [(i: Int, j: Int, similarity: Float)] {
        let simMatrix = cosineSimilarityMatrix(embeddings)
        var pairs: [(i: Int, j: Int, similarity: Float)] = []

        // Upper triangle only (i < j)
        for i in 0..<simMatrix.count {
            for j in (i + 1)..<simMatrix[i].count {
                if simMatrix[i][j] > threshold {
                    pairs.append((i: i, j: j, similarity: simMatrix[i][j]))
                }
            }
        }

        return pairs.sorted { $0.similarity > $1.similarity }
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
