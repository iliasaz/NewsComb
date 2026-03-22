import Accelerate
import Foundation
import OSLog

/// Principal Component Analysis (PCA) service using Accelerate's LAPACK routines.
///
/// Reduces high-dimensional vectors to a lower-dimensional space by projecting
/// onto the top-k principal components (eigenvectors of the covariance matrix).
/// This is a standard pre-processing step before UMAP to speed up kNN search
/// and remove noise dimensions.
final class PCAService: Sendable {

    /// Configuration for PCA dimensionality reduction.
    struct Parameters {
        /// Target number of output dimensions.
        var targetDimension: Int = 50
    }

    /// Result of a PCA projection, carrying the projected data and metadata
    /// needed for diagnostics or incremental projection.
    struct PCAResult {
        /// The projected vectors, each of length `targetDimension`.
        let projectedVectors: [[Float]]
        /// Fraction of total variance explained by the retained components.
        let explainedVarianceRatio: Float
    }

    private let logger = Logger(subsystem: "com.newscomb", category: "PCAService")

    // MARK: - Public API

    /// Projects a set of high-dimensional vectors to `params.targetDimension` dimensions.
    ///
    /// Uses the covariance-matrix approach:
    /// 1. Mean-center the data
    /// 2. Compute D×D covariance matrix via `vDSP_mmul`
    /// 3. Eigendecompose via LAPACK `ssyev_`
    /// 4. Project onto top-k eigenvectors
    ///
    /// - Parameters:
    ///   - vectors: Array of N vectors, each of dimension D.
    ///   - params: PCA configuration (target dimension).
    /// - Returns: A `PCAResult` with the reduced vectors and explained variance ratio.
    func project(vectors: [[Float]], params: Parameters = Parameters()) -> PCAResult {
        let n = vectors.count
        guard n >= 2, let d = vectors.first?.count, d > 0 else {
            return PCAResult(projectedVectors: vectors, explainedVarianceRatio: 1.0)
        }

        let k = min(params.targetDimension, d, n)
        guard k < d else {
            logger.info("Target dimension (\(k)) >= input dimension (\(d)); skipping PCA")
            return PCAResult(projectedVectors: vectors, explainedVarianceRatio: 1.0)
        }

        logger.info("PCA: \(n) vectors × \(d)D → \(k)D")
        let startTime = ContinuousClock.now

        // Step 1: Flatten and compute the mean vector
        var flat = [Float](repeating: 0, count: n * d)
        for i in 0..<n {
            flat.replaceSubrange((i * d)..<((i + 1) * d), with: vectors[i])
        }

        var mean = [Float](repeating: 0, count: d)
        computeMean(flat: flat, n: n, d: d, mean: &mean)

        // Step 2: Mean-center the data in-place
        centerData(flat: &flat, mean: mean, n: n, d: d)

        // Step 3: Compute the D×D covariance matrix: C = (1/(n-1)) Xᵀ X
        var covMatrix = computeCovarianceMatrix(flat: flat, n: n, d: d)

        // Step 4: Eigendecompose the covariance matrix via LAPACK ssyev_
        var eigenvalues = [Float](repeating: 0, count: d)
        eigendecompose(matrix: &covMatrix, eigenvalues: &eigenvalues, d: d)

        // ssyev_ returns eigenvalues in ascending order, so the top-k
        // eigenvectors are the last k columns of the matrix.
        let totalVariance = eigenvalues.reduce(0, +)
        let retainedVariance = eigenvalues.suffix(k).reduce(0, +)
        let explainedRatio = totalVariance > 0 ? retainedVariance / totalVariance : 1.0

        // Step 5: Extract top-k eigenvectors (columns) as the projection matrix
        // covMatrix is column-major after ssyev_, so column j starts at index j*d.
        // We want the last k columns (highest eigenvalues).
        var projectionMatrix = [Float](repeating: 0, count: d * k)
        for j in 0..<k {
            let srcCol = d - k + j // column index in eigendecomposed matrix
            let srcOffset = srcCol * d
            let dstOffset = j * d
            projectionMatrix.replaceSubrange(dstOffset..<(dstOffset + d),
                                             with: covMatrix[srcOffset..<(srcOffset + d)])
        }

        // Step 6: Project all vectors: Y = X_centered × P
        // X_centered is n×d (row-major), P is d×k (column-major, but we treat as row-major d×k)
        // Result Y is n×k
        var projected = [Float](repeating: 0, count: n * k)
        vDSP_mmul(flat, 1,              // A: n×d (row-major)
                  projectionMatrix, 1,   // B: d×k (column-major = row-major for our layout)
                  &projected, 1,         // C: n×k
                  vDSP_Length(n),
                  vDSP_Length(k),
                  vDSP_Length(d))

        // Step 7: Reshape to [[Float]]
        var result: [[Float]] = []
        result.reserveCapacity(n)
        for i in 0..<n {
            let start = i * k
            result.append(Array(projected[start..<(start + k)]))
        }

        let elapsed = ContinuousClock.now - startTime
        logger.info("PCA complete: \(d)D → \(k)D, explained variance: \(String(format: "%.1f", explainedRatio * 100))%, time: \(elapsed)")

        return PCAResult(projectedVectors: result, explainedVarianceRatio: explainedRatio)
    }

    // MARK: - Private Helpers

    /// Computes the column-wise mean of a flattened n×d matrix.
    private func computeMean(flat: [Float], n: Int, d: Int, mean: inout [Float]) {
        // Sum each column across all rows
        flat.withUnsafeBufferPointer { buf in
            for i in 0..<n {
                vDSP_vadd(mean, 1, buf.baseAddress! + i * d, 1, &mean, 1, vDSP_Length(d))
            }
        }
        // Divide by n
        var scale = 1.0 / Float(n)
        vDSP_vsmul(mean, 1, &scale, &mean, 1, vDSP_Length(d))
    }

    /// Mean-centers the flattened n×d matrix in-place.
    private func centerData(flat: inout [Float], mean: [Float], n: Int, d: Int) {
        flat.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                // row[i] -= mean
                vDSP_vsub(mean, 1, buf.baseAddress! + i * d, 1,
                          buf.baseAddress! + i * d, 1, vDSP_Length(d))
            }
        }
    }

    /// Computes the D×D covariance matrix: C = (1/(n-1)) Xᵀ X.
    ///
    /// The result is stored in column-major order (required by LAPACK).
    private func computeCovarianceMatrix(flat: [Float], n: Int, d: Int) -> [Float] {
        // Xᵀ X via vDSP_mmul
        // X is n×d row-major. We need Xᵀ (d×n) × X (n×d) = d×d.
        // Transpose X first.
        var transposed = [Float](repeating: 0, count: d * n)
        vDSP_mtrans(flat, 1, &transposed, 1, vDSP_Length(d), vDSP_Length(n))

        var cov = [Float](repeating: 0, count: d * d)
        vDSP_mmul(transposed, 1,  // Xᵀ: d×n
                  flat, 1,         // X: n×d
                  &cov, 1,         // C: d×d
                  vDSP_Length(d),
                  vDSP_Length(d),
                  vDSP_Length(n))

        // Scale by 1/(n-1) for unbiased estimate
        let denom = max(1, n - 1)
        var scale = 1.0 / Float(denom)
        vDSP_vsmul(cov, 1, &scale, &cov, 1, vDSP_Length(d * d))

        return cov
    }

    /// Eigendecomposes a symmetric D×D matrix in-place using LAPACK ssyev_.
    ///
    /// On output, `matrix` contains the eigenvectors as columns (column-major),
    /// and `eigenvalues` contains the eigenvalues in ascending order.
    private func eigendecompose(matrix: inout [Float], eigenvalues: inout [Float], d: Int) {
        var jobz: CChar = CChar(Character("V").asciiValue!) // Compute eigenvectors
        var uplo: CChar = CChar(Character("U").asciiValue!) // Upper triangle
        var n = Int32(d)
        var lda = Int32(d)
        var info: Int32 = 0

        // Query optimal workspace size
        var workQuery: Float = 0
        var lwork: Int32 = -1
        ssyev_(&jobz, &uplo, &n, &matrix, &lda, &eigenvalues, &workQuery, &lwork, &info)

        lwork = Int32(workQuery)
        var workspace = [Float](repeating: 0, count: Int(lwork))
        ssyev_(&jobz, &uplo, &n, &matrix, &lda, &eigenvalues, &workspace, &lwork, &info)

        if info != 0 {
            logger.error("ssyev_ failed with info=\(info)")
        }
    }
}
