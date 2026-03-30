import Accelerate
import Foundation
import OSLog

/// Pure-Swift HDBSCAN (Hierarchical Density-Based Spatial Clustering of Applications with Noise)
/// implementation using Accelerate for distance computations.
///
/// Algorithm steps:
/// 1. Compute core distances (k-th nearest neighbor distance for each point)
/// 2. Build mutual reachability graph
/// 3. Compute minimum spanning tree (Prim's algorithm)
/// 4. Build condensed cluster tree
/// 5. Select clusters using Excess of Mass (EOM)
final class HDBSCANService: Sendable {

    /// Result of running HDBSCAN clustering.
    struct ClusterResult {
        /// Cluster label for each point. -1 means noise.
        let labels: [Int]
        /// Membership strength for each point (0..1). Higher = more confident assignment.
        let memberships: [Double]
        /// Number of clusters found (excluding noise).
        let clusterCount: Int
    }

    /// Distance metric for clustering.
    enum DistanceMetric {
        /// Euclidean (L2) distance.
        case euclidean
        /// Cosine distance: `1 - cos(a, b)`. Better for high-dimensional normalized vectors.
        case cosine
    }

    /// Configuration parameters for HDBSCAN.
    struct Parameters {
        /// Minimum number of points to form a cluster.
        var minClusterSize: Int = 20
        /// Number of neighbors for core distance computation.
        var minSamples: Int = 10
        /// Distance metric.
        var metric: DistanceMetric = .cosine

        /// Validates and adjusts parameters for the data size.
        ///
        /// Scales `minClusterSize` with half the square root of the data size.
        /// This balances mega-cluster prevention with allowing coherent small
        /// topics to survive. For N=100 → 20, N=1K → 20, N=15K → 61, N=50K → 112.
        func validated(forDataSize n: Int) -> Parameters {
            var p = self
            let scaled = max(20, Int(Double(n).squareRoot() / 2))
            p.minClusterSize = min(scaled, max(2, n / 5))
            p.minSamples = min(p.minSamples, p.minClusterSize)
            return p
        }
    }

    private let logger = Logger(subsystem: "com.newscomb", category: "HDBSCANService")

    // MARK: - Public API

    /// Runs HDBSCAN clustering on a set of vectors.
    ///
    /// - Parameters:
    ///   - vectors: Array of N vectors, each of dimension D (stored as contiguous `[Float]`).
    ///   - params: HDBSCAN parameters (minClusterSize, minSamples).
    /// - Returns: A `ClusterResult` with labels, memberships, and cluster count.
    func cluster(vectors: [[Float]], params: Parameters = Parameters()) -> ClusterResult {
        let n = vectors.count
        guard n >= 2 else {
            return ClusterResult(labels: Array(repeating: -1, count: n), memberships: Array(repeating: 0, count: n), clusterCount: 0)
        }

        let params = params.validated(forDataSize: n)
        logger.info("Running HDBSCAN: n=\(n), minClusterSize=\(params.minClusterSize), minSamples=\(params.minSamples), metric=\(String(describing: params.metric))")
        let pipelineStart = ContinuousClock.now

        // Step 1: Compute pairwise distances and core distances
        logger.info("Step 1a: Computing \(n)x\(n) distance matrix...")
        let distances: [Float]
        switch params.metric {
        case .euclidean:
            distances = computeEuclideanDistanceMatrix(vectors)
        case .cosine:
            distances = computeCosineDistanceMatrix(vectors)
        }
        logger.info("Step 1a: Distance matrix computed in \(ContinuousClock.now - pipelineStart)")

        logger.info("Step 1b: Computing core distances (k=\(params.minSamples))...")
        let stepStart = ContinuousClock.now
        let coreDistances = computeCoreDistances(distances: distances, minSamples: params.minSamples)
        logger.info("Step 1b: Core distances computed in \(ContinuousClock.now - stepStart)")

        // Step 2: Build MST on mutual reachability graph
        logger.info("Step 2: Building MST via Prim's algorithm...")
        let mstStart = ContinuousClock.now
        let mst = buildMST(distances: distances, coreDistances: coreDistances, n: n)
        logger.info("Step 2: MST built in \(ContinuousClock.now - mstStart)")

        // Step 3: Build condensed cluster tree
        logger.info("Step 3: Building condensed cluster tree...")
        let treeInfo = buildCondensedTree(mst: mst, n: n, minClusterSize: params.minClusterSize)

        // Step 4: Select clusters via EOM
        logger.info("Step 4: Selecting clusters via EOM...")
        let (labels, memberships, clusterCount) = selectClusters(treeInfo: treeInfo)

        logger.info("HDBSCAN found \(clusterCount) clusters with \(labels.filter { $0 == -1 }.count) noise points")
        return ClusterResult(labels: labels, memberships: memberships, clusterCount: clusterCount)
    }

    // MARK: - Sparse kNN-Based Clustering

    /// Runs HDBSCAN using a pre-computed kNN graph, avoiding the N² distance matrix.
    ///
    /// This is the large-scale path: instead of computing all pairwise distances
    /// (which requires N²×4 bytes — 32 GB at N=89K), it uses the kNN graph to:
    /// 1. Derive core distances directly (k-th neighbor distance per point)
    /// 2. Build the MST on the sparse mutual reachability graph (kNN edges only)
    ///
    /// The condensed tree and EOM cluster selection are identical to the dense path.
    func clusterWithKNN(
        knn: VPTreeService.KNNResult,
        vectors: [[Float]],
        params: Parameters = Parameters()
    ) -> ClusterResult {
        let n = vectors.count
        guard n >= 2 else {
            return ClusterResult(labels: Array(repeating: -1, count: n), memberships: Array(repeating: 0, count: n), clusterCount: 0)
        }

        let params = params.validated(forDataSize: n)
        logger.info("Running HDBSCAN (sparse kNN): n=\(n), minClusterSize=\(params.minClusterSize), minSamples=\(params.minSamples)")
        let pipelineStart = ContinuousClock.now

        // Step 1: Core distances from kNN (the minSamples-th neighbor distance)
        let k = min(params.minSamples, knn.distances[0].count)
        var coreDistances = [Float](repeating: .infinity, count: n)
        for i in 0..<n {
            if k - 1 < knn.distances[i].count {
                coreDistances[i] = knn.distances[i][k - 1]
            }
        }
        logger.info("Step 1: Core distances computed from kNN in \(ContinuousClock.now - pipelineStart)")

        // Step 2: Build sparse adjacency from kNN graph (bidirectional)
        // For each point, its kNN neighbors form the sparse graph edges.
        // We need bidirectional edges for Prim's: if A→B is a kNN edge, also add B→A.
        var adjacency: [[Int]] = Array(repeating: [], count: n)
        var edgeDistances: [Int64: Float] = [:] // packed (min,max) → distance

        for i in 0..<n {
            for (jIdx, j) in knn.indices[i].enumerated() {
                let dist = knn.distances[i][jIdx]
                let lo = min(i, j)
                let hi = max(i, j)
                let key = Int64(lo) * Int64(n) + Int64(hi)

                if edgeDistances[key] == nil {
                    adjacency[i].append(j)
                    adjacency[j].append(i)
                    edgeDistances[key] = dist
                }
            }
        }
        logger.info("Step 2: Sparse adjacency built (\(edgeDistances.count) edges) in \(ContinuousClock.now - pipelineStart)")

        // Step 3: Build MST via Prim's on the sparse mutual reachability graph.
        // Uses a priority-queue approach: for each non-MST vertex, track the best
        // known edge weight from any MST vertex (via kNN adjacency).
        let mstStart = ContinuousClock.now
        let mst = buildSparseMST(
            adjacency: adjacency,
            edgeDistances: edgeDistances,
            coreDistances: coreDistances,
            vectors: vectors,
            n: n
        )
        logger.info("Step 3: Sparse MST built (\(mst.count) edges) in \(ContinuousClock.now - mstStart)")

        // Steps 4-5: Condensed tree + EOM (identical to dense path)
        logger.info("Step 4: Building condensed cluster tree...")
        let treeInfo = buildCondensedTree(mst: mst, n: n, minClusterSize: params.minClusterSize)

        logger.info("Step 5: Selecting clusters via EOM...")
        let (labels, memberships, clusterCount) = selectClusters(treeInfo: treeInfo)

        logger.info("HDBSCAN found \(clusterCount) clusters with \(labels.filter { $0 == -1 }.count) noise points in \(ContinuousClock.now - pipelineStart)")
        return ClusterResult(labels: labels, memberships: memberships, clusterCount: clusterCount)
    }

    /// Builds the MST via Prim's algorithm on the sparse kNN mutual reachability graph.
    ///
    /// When the best kNN edge would leave disconnected components, computes the
    /// exact distance on-demand for the nearest non-MST vertex (lazy fallback).
    private func buildSparseMST(
        adjacency: [[Int]],
        edgeDistances: [Int64: Float],
        coreDistances: [Float],
        vectors: [[Float]],
        n: Int
    ) -> [MSTEdge] {
        var inMST = [Bool](repeating: false, count: n)
        var minEdge = [Float](repeating: .infinity, count: n)
        var bestNeighbor = [Int](repeating: -1, count: n)
        var edges: [MSTEdge] = []
        edges.reserveCapacity(n - 1)

        // Start from vertex 0 — initialize from its kNN neighbors
        inMST[0] = true
        for j in adjacency[0] {
            let dist = lookupDistance(i: 0, j: j, n: n, edgeDistances: edgeDistances)
            let mr = max(coreDistances[0], coreDistances[j], dist)
            if mr < minEdge[j] {
                minEdge[j] = mr
                bestNeighbor[j] = 0
            }
        }

        for step in 1..<n {
            // Find the minimum edge to a non-MST vertex
            var bestVertex = -1
            var bestWeight: Float = .infinity

            for j in 0..<n {
                if !inMST[j] && minEdge[j] < bestWeight {
                    bestWeight = minEdge[j]
                    bestVertex = j
                }
            }

            // If no reachable vertex found, compute distances on-demand
            // to the nearest unreachable vertex (handles disconnected kNN graph)
            if bestVertex == -1 || bestWeight == .infinity {
                for j in 0..<n where !inMST[j] {
                    // Find the nearest MST vertex by computing exact distance
                    for mstV in 0..<n where inMST[mstV] {
                        let dist = cosineDistance(vectors[mstV], vectors[j])
                        let mr = max(coreDistances[mstV], coreDistances[j], dist)
                        if mr < minEdge[j] {
                            minEdge[j] = mr
                            bestNeighbor[j] = mstV
                        }
                    }
                    if minEdge[j] < bestWeight {
                        bestWeight = minEdge[j]
                        bestVertex = j
                    }
                }
            }

            guard bestVertex >= 0 else { break }

            inMST[bestVertex] = true
            edges.append(MSTEdge(u: bestNeighbor[bestVertex], v: bestVertex, weight: bestWeight))

            // Update neighbors via sparse adjacency
            for j in adjacency[bestVertex] where !inMST[j] {
                let dist = lookupDistance(i: bestVertex, j: j, n: n, edgeDistances: edgeDistances)
                let mr = max(coreDistances[bestVertex], coreDistances[j], dist)
                if mr < minEdge[j] {
                    minEdge[j] = mr
                    bestNeighbor[j] = bestVertex
                }
            }

            if step % 10000 == 0 {
                logger.info("Sparse MST progress: \(step)/\(n - 1)")
            }
        }

        return edges.sorted()
    }

    /// Looks up a distance from the sparse edge dictionary.
    @inline(__always)
    private func lookupDistance(i: Int, j: Int, n: Int, edgeDistances: [Int64: Float]) -> Float {
        let lo = min(i, j)
        let hi = max(i, j)
        let key = Int64(lo) * Int64(n) + Int64(hi)
        return edgeDistances[key] ?? .infinity
    }

    /// Computes cosine distance between two vectors (on-demand fallback).
    private func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        1.0 - AccelerateVectorOps.cosineSimilarity(a, b)
    }

    // MARK: - Step 1: Distance Matrix & Core Distances

    /// Flattens vectors and computes the NxN dot-product matrix A·Aᵀ using
    /// `vDSP_mmul` (the non-deprecated Accelerate matrix multiply).
    /// Also returns per-vector squared norms via `vDSP_svesq`.
    private func computeDotProductMatrix(_ vectors: [[Float]]) -> (dots: [Float], normsSq: [Float], n: Int) {
        let n = vectors.count
        guard let dim = vectors.first?.count else { return ([], [], 0) }

        // Flatten into a contiguous row-major matrix
        var flat = [Float](repeating: 0, count: n * dim)
        for i in 0..<n {
            flat.replaceSubrange((i * dim)..<((i + 1) * dim), with: vectors[i])
        }

        // Per-vector squared norms: ||a||² = Σ aᵢ²
        var normsSq = [Float](repeating: 0, count: n)
        flat.withUnsafeBufferPointer { flatBuf in
            for i in 0..<n {
                vDSP_svesq(flatBuf.baseAddress! + i * dim, 1, &normsSq[i], vDSP_Length(dim))
            }
        }

        // A·Aᵀ via vDSP_mmul (replaces deprecated cblas_sgemm).
        // vDSP_mmul(A, 1, B, 1, C, 1, M, N, P) computes C[M×N] = A[M×P] * B[P×N].
        // For A·Aᵀ we need B = Aᵀ, so: M=N=n, P=dim.
        // vDSP_mmul expects the *transposed* matrix pre-transposed in memory.
        var transposed = [Float](repeating: 0, count: dim * n)
        vDSP_mtrans(flat, 1, &transposed, 1, vDSP_Length(dim), vDSP_Length(n))

        var dots = [Float](repeating: 0, count: n * n)
        vDSP_mmul(flat, 1, transposed, 1, &dots, 1,
                  vDSP_Length(n), vDSP_Length(n), vDSP_Length(dim))

        return (dots, normsSq, n)
    }

    /// Computes the full NxN Euclidean distance matrix using Accelerate.
    ///
    /// dist(a,b) = √(||a||² + ||b||² − 2·a·b)
    ///
    /// Fully vectorized: builds the N×N ||a||²+||b||² matrix via outer sum,
    /// subtracts 2·dots, clamps negatives, and batch-sqrts with `vvsqrtf`.
    private func computeEuclideanDistanceMatrix(_ vectors: [[Float]]) -> [Float] {
        let (dots, normsSq, n) = computeDotProductMatrix(vectors)
        guard n > 0 else { return [] }
        let nn = n * n

        // Build N×N matrix where [i,j] = ||a_i||² + ||b_j||²
        // = outer sum of normsSq with itself.
        // Row broadcast: each row i is filled with normsSq[i] + normsSq[:]
        var normSumMatrix = [Float](repeating: 0, count: nn)
        normSumMatrix.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                var val = normsSq[i]
                vDSP_vsadd(normsSq, 1, &val, buf.baseAddress! + i * n, 1, vDSP_Length(n))
            }
        }

        // distances = normSumMatrix - 2 * dots
        var minusTwo: Float = -2.0
        vDSP_vsma(dots, 1, &minusTwo, normSumMatrix, 1, &normSumMatrix, 1, vDSP_Length(nn))

        // Clamp negatives to zero (floating-point rounding can produce tiny negatives)
        var zero: Float = 0
        vDSP_vthres(normSumMatrix, 1, &zero, &normSumMatrix, 1, vDSP_Length(nn))

        // Batch sqrt
        var distances = [Float](repeating: 0, count: nn)
        var count = Int32(nn)
        vvsqrtf(&distances, normSumMatrix, &count)

        // Zero the diagonal
        for i in 0..<n {
            distances[i * n + i] = 0
        }

        return distances
    }

    /// Computes the full NxN cosine distance matrix using Accelerate.
    ///
    /// cosine_distance(a,b) = 1 − (a·b)/(||a||·||b||)
    ///
    /// Fully vectorized: builds the N×N norm-product matrix via outer product
    /// of L2 norms, divides dots element-wise, then subtracts from 1.
    private func computeCosineDistanceMatrix(_ vectors: [[Float]]) -> [Float] {
        let (dots, normsSq, n) = computeDotProductMatrix(vectors)
        guard n > 0 else { return [] }
        let nn = n * n

        // L2 norms: √(normsSq)
        var norms = [Float](repeating: 0, count: n)
        var sqrtCount = Int32(n)
        vvsqrtf(&norms, normsSq, &sqrtCount)

        // Build N×N denominator matrix: denom[i,j] = ||a_i|| * ||b_j||
        // This is the outer product of the norms vector with itself.
        var denomMatrix = [Float](repeating: 0, count: nn)
        denomMatrix.withUnsafeMutableBufferPointer { buf in
            for i in 0..<n {
                var val = norms[i]
                vDSP_vsmul(norms, 1, &val, buf.baseAddress! + i * n, 1, vDSP_Length(n))
            }
        }

        // cosine_similarity = dots / denomMatrix (element-wise)
        // vDSP_vdiv divides B[i]/A[i], so pass denom as A and dots as B.
        var similarity = [Float](repeating: 0, count: nn)
        vDSP_vdiv(denomMatrix, 1, dots, 1, &similarity, 1, vDSP_Length(nn))

        // cosine_distance = 1 - similarity
        var one: Float = 1.0
        var negOne: Float = -1.0
        var distances = [Float](repeating: 0, count: nn)
        // distances = one + (-1 * similarity) = 1 - similarity
        vDSP_vsmsma(similarity, 1, &negOne, similarity, 1, &one, &distances, 1, vDSP_Length(nn))
        // vsmsma doesn't do what we want — use vDSP_vsadd on negated similarity instead
        vDSP_vneg(similarity, 1, &distances, 1, vDSP_Length(nn))
        vDSP_vsadd(distances, 1, &one, &distances, 1, vDSP_Length(nn))

        // Clamp negatives from floating-point rounding
        var zero: Float = 0
        vDSP_vthres(distances, 1, &zero, &distances, 1, vDSP_Length(nn))

        // Zero the diagonal
        for i in 0..<n {
            distances[i * n + i] = 0
        }

        // Handle zero-norm vectors (denom=0 → division produced NaN/Inf)
        // Replace any NaN/Inf with 1.0 (maximally dissimilar)
        for i in 0..<nn {
            if distances[i].isNaN || distances[i].isInfinite {
                distances[i] = 1.0
            }
        }

        return distances
    }

    /// Computes core distance for each point (distance to the k-th nearest neighbor).
    ///
    /// Uses a streaming k-smallest algorithm instead of sorting the full row:
    /// maintains a sorted buffer of (k+1) smallest distances, giving O(n) per
    /// row instead of O(n log n). For k=10 and n=54K this is ~1600x faster.
    private func computeCoreDistances(distances: [Float], minSamples: Int) -> [Float] {
        let n = Int(sqrt(Double(distances.count)))
        var coreDistances = [Float](repeating: 0, count: n)
        let k = min(minSamples, n - 1)
        let bufSize = k + 1  // +1 because index 0 is self-distance (0.0)

        let startTime = ContinuousClock.now

        distances.withUnsafeBufferPointer { distBuf in
            for i in 0..<n {
                let rowStart = i * n
                // Track the (k+1) smallest distances in sorted order.
                // Self-distance [i,i] = 0 occupies one slot, so the k-th
                // nearest neighbor ends up at index k.
                var smallest = [Float](repeating: Float.infinity, count: bufSize)

                for j in 0..<n {
                    let d = distBuf[rowStart + j]
                    if d < smallest[bufSize - 1] {
                        smallest[bufSize - 1] = d
                        // Insertion-sort the new value into place (bufSize is ~11)
                        var idx = bufSize - 1
                        while idx > 0 && smallest[idx] < smallest[idx - 1] {
                            smallest.swapAt(idx, idx - 1)
                            idx -= 1
                        }
                    }
                }

                coreDistances[i] = smallest[k]

                if (i + 1) % 10000 == 0 || i == n - 1 {
                    let elapsed = ContinuousClock.now - startTime
                    let pct = Int(Double(i + 1) / Double(n) * 100)
                    logger.info("Core distances: \(i + 1)/\(n) (\(pct)%) — elapsed \(elapsed)")
                }
            }
        }

        return coreDistances
    }

    // MARK: - Step 2: Minimum Spanning Tree (Prim's on Mutual Reachability)

    /// An edge in the minimum spanning tree.
    struct MSTEdge: Comparable {
        let u: Int
        let v: Int
        let weight: Float

        static func < (lhs: MSTEdge, rhs: MSTEdge) -> Bool {
            lhs.weight < rhs.weight
        }
    }

    /// Builds the MST using Prim's algorithm on the mutual reachability graph.
    ///
    /// Mutual reachability: `mr(a,b) = max(core(a), core(b), dist(a,b))`
    private func buildMST(distances: [Float], coreDistances: [Float], n: Int) -> [MSTEdge] {
        var inMST = [Bool](repeating: false, count: n)
        var minEdge = [Float](repeating: .infinity, count: n)
        var bestNeighbor = [Int](repeating: -1, count: n)
        var edges: [MSTEdge] = []
        edges.reserveCapacity(n - 1)

        // Start from vertex 0
        inMST[0] = true
        for j in 1..<n {
            let mr = mutualReachability(distances: distances, coreDistances: coreDistances, i: 0, j: j, n: n)
            minEdge[j] = mr
            bestNeighbor[j] = 0
        }

        for step in 1..<n {
            // Find the minimum edge to a non-MST vertex
            var bestVertex = -1
            var bestWeight: Float = .infinity

            for j in 0..<n {
                if !inMST[j] && minEdge[j] < bestWeight {
                    bestWeight = minEdge[j]
                    bestVertex = j
                }
            }

            guard bestVertex >= 0 else { break }

            inMST[bestVertex] = true
            edges.append(MSTEdge(u: bestNeighbor[bestVertex], v: bestVertex, weight: bestWeight))

            // Update minimum edges for remaining non-MST vertices
            for j in 0..<n where !inMST[j] {
                let mr = mutualReachability(distances: distances, coreDistances: coreDistances, i: bestVertex, j: j, n: n)
                if mr < minEdge[j] {
                    minEdge[j] = mr
                    bestNeighbor[j] = bestVertex
                }
            }

            if step % 10000 == 0 {
                logger.info("MST progress: \(step)/\(n - 1) (\(Int(Double(step) / Double(n - 1) * 100))%)")
            }
        }

        return edges.sorted()
    }

    /// Computes mutual reachability distance between points i and j.
    @inline(__always)
    private func mutualReachability(distances: [Float], coreDistances: [Float], i: Int, j: Int, n: Int) -> Float {
        max(coreDistances[i], coreDistances[j], distances[i * n + j])
    }

    // MARK: - Step 3: Condensed Cluster Tree

    /// A node in the condensed cluster tree.
    struct CondensedNode {
        let parent: Int
        let child: Int
        let lambdaVal: Double  // 1/distance at which this split occurs
        let childSize: Int
    }

    /// Bundled output from condensed tree construction, carrying the hierarchy
    /// information needed for correct point-to-cluster assignment.
    private struct TreeInfo {
        let condensed: [CondensedNode]
        /// Dendrogram parent→children map for recursive descendant lookup.
        let dendrogramChildren: [Int: (left: Int, right: Int)]
        /// Maps each condensed cluster ID to the dendrogram cluster whose
        /// leaf descendants are the condensed cluster's members.
        let condensedToDendro: [Int: Int]
        let n: Int
    }

    /// Builds the condensed cluster tree from the MST.
    ///
    /// The condensed tree collapses chains of small-child merges into a single
    /// cluster, only recording "real splits" where both children meet the
    /// minimum cluster size threshold.
    private func buildCondensedTree(mst: [MSTEdge], n: Int, minClusterSize: Int) -> TreeInfo {
        let sortedEdges = mst

        // Union-Find for merging
        var parent = Array(0..<(2 * n))
        var size = [Int](repeating: 1, count: 2 * n)
        var nextCluster = n  // New cluster IDs start after individual points

        func find(_ x: Int) -> Int {
            var x = x
            while parent[x] != x {
                parent[x] = parent[parent[x]]
                x = parent[x]
            }
            return x
        }

        // Build the single-linkage dendrogram
        struct DendrogramEntry {
            let left: Int
            let right: Int
            let distance: Float
            let mergedSize: Int
            let newCluster: Int
        }

        var dendrogram: [DendrogramEntry] = []
        var dendrogramChildren: [Int: (left: Int, right: Int)] = [:]

        for edge in sortedEdges {
            let rootU = find(edge.u)
            let rootV = find(edge.v)

            guard rootU != rootV else { continue }

            let cluster = nextCluster
            nextCluster += 1

            // Ensure parent array is large enough
            while parent.count <= cluster {
                parent.append(parent.count)
                size.append(0)
            }

            let mergedSize = size[rootU] + size[rootV]
            parent[rootU] = cluster
            parent[rootV] = cluster
            parent[cluster] = cluster
            size[cluster] = mergedSize

            dendrogramChildren[cluster] = (left: rootU, right: rootV)

            dendrogram.append(DendrogramEntry(
                left: rootU,
                right: rootV,
                distance: edge.weight,
                mergedSize: mergedSize,
                newCluster: cluster
            ))
        }

        // Condense the tree: collapse chains of small-child merges into a
        // single persistent cluster. Only record "real splits" where both
        // children meet minClusterSize.
        var condensed: [CondensedNode] = []
        var clusterMap: [Int: Int] = [:]
        var condensedToDendro: [Int: Int] = [:]

        for entry in dendrogram {
            let lambda = entry.distance > 0 ? 1.0 / Double(entry.distance) : Double.infinity

            let leftSize = size[entry.left] > 0 ? size[entry.left] : 1
            let rightSize = size[entry.right] > 0 ? size[entry.right] : 1

            if leftSize >= minClusterSize && rightSize >= minClusterSize {
                // Real split: both children become their own condensed clusters.
                let leftCluster = clusterMap[entry.left] ?? entry.left
                let rightCluster = clusterMap[entry.right] ?? entry.right
                let parentCluster = clusterMap[entry.newCluster] ?? entry.newCluster

                clusterMap[entry.left] = leftCluster
                clusterMap[entry.right] = rightCluster

                condensedToDendro[leftCluster] = entry.left
                condensedToDendro[rightCluster] = entry.right
                condensedToDendro[parentCluster] = entry.newCluster

                condensed.append(CondensedNode(
                    parent: parentCluster, child: leftCluster,
                    lambdaVal: lambda, childSize: leftSize
                ))
                condensed.append(CondensedNode(
                    parent: parentCluster, child: rightCluster,
                    lambdaVal: lambda, childSize: rightSize
                ))
            } else {
                // At least one child is below minClusterSize.
                // Keep the larger child (more likely to carry an existing
                // condensed cluster identity) and fall out the smaller one.
                let keepLeft = leftSize >= rightSize
                let surviveChild = keepLeft ? entry.left : entry.right
                let fallChild = keepLeft ? entry.right : entry.left
                let fallSize = keepLeft ? rightSize : leftSize

                // Inherit identity: prefer the surviving child's existing
                // condensed ID, then the falling child's, then a new one.
                let survivingCluster = clusterMap[surviveChild]
                    ?? clusterMap[fallChild]
                    ?? entry.newCluster
                clusterMap[entry.newCluster] = survivingCluster
                clusterMap[surviveChild] = survivingCluster
                condensedToDendro[survivingCluster] = entry.newCluster

                condensed.append(CondensedNode(
                    parent: survivingCluster, child: fallChild,
                    lambdaVal: lambda, childSize: fallSize
                ))
            }
        }

        return TreeInfo(
            condensed: condensed,
            dendrogramChildren: dendrogramChildren,
            condensedToDendro: condensedToDendro,
            n: n
        )
    }

    // MARK: - Step 4: EOM Cluster Selection

    /// Selects clusters from the condensed tree using Excess of Mass (EOM),
    /// then assigns every point to its selected cluster using the dendrogram.
    private func selectClusters(treeInfo: TreeInfo) -> (labels: [Int], memberships: [Double], clusterCount: Int) {
        let n = treeInfo.n
        let tree = treeInfo.condensed

        guard !tree.isEmpty else {
            return (Array(repeating: -1, count: n), Array(repeating: 0, count: n), 0)
        }

        // Find all cluster IDs (non-leaf nodes that appear as parents)
        var clusterIds = Set<Int>()
        var childClusterIds = Set<Int>()

        for node in tree {
            clusterIds.insert(node.parent)
            if node.childSize > 1 {
                childClusterIds.insert(node.child)
            }
        }

        let allClusterIds = clusterIds.union(childClusterIds)

        // Compute stability for each cluster
        // Stability = sum of (lambda_p - lambda_birth) for each point p in the cluster
        var stability: [Int: Double] = [:]
        var birthLambda: [Int: Double] = [:]

        for node in tree {
            if childClusterIds.contains(node.child) {
                birthLambda[node.child] = node.lambdaVal
            }
        }

        for node in tree where node.childSize == 1 {
            let cluster = node.parent
            let birth = birthLambda[cluster] ?? 0
            let contribution = node.lambdaVal - birth
            stability[cluster, default: 0] += max(0, contribution)
        }

        // Bottom-up EOM selection
        var clusterChildren: [Int: [Int]] = [:]
        for node in tree where childClusterIds.contains(node.child) {
            clusterChildren[node.parent, default: []].append(node.child)
        }

        var selected = Set<Int>()
        let sortedClusters = allClusterIds.sorted()

        for clusterId in sortedClusters.reversed() {
            let children = clusterChildren[clusterId] ?? []

            if children.isEmpty {
                selected.insert(clusterId)
            } else {
                let childStabilitySum = children.reduce(0.0) { $0 + (stability[$1] ?? 0) }
                let ownStability = stability[clusterId] ?? 0

                if ownStability >= childStabilitySum {
                    selected.insert(clusterId)
                    for child in children {
                        selected.remove(child)
                    }
                } else {
                    stability[clusterId] = childStabilitySum
                }
            }
        }

        if selected.isEmpty {
            if let root = clusterIds.max() {
                selected.insert(root)
            }
        }

        // Assign labels using dendrogram descendant lookup
        var pointLabels = [Int](repeating: -1, count: n)
        var pointMemberships = [Double](repeating: 0, count: n)
        let labelMap = Dictionary(uniqueKeysWithValues: selected.sorted().enumerated().map { ($1, $0) })

        for clusterId in selected {
            guard let label = labelMap[clusterId],
                  let dendroId = treeInfo.condensedToDendro[clusterId] else { continue }
            let points = leafDescendants(
                of: dendroId,
                children: treeInfo.dendrogramChildren,
                n: n
            )
            for point in points {
                pointLabels[point] = label
                pointMemberships[point] = 1.0
            }
        }

        return (pointLabels, pointMemberships, labelMap.count)
    }

    /// Finds all original point indices (< n) that are leaf descendants
    /// of the given dendrogram cluster.
    ///
    /// Uses an iterative traversal with an explicit stack to avoid stack
    /// overflow on deep dendrograms (O(n) depth is common with single-linkage).
    private func leafDescendants(
        of cluster: Int,
        children: [Int: (left: Int, right: Int)],
        n: Int
    ) -> Set<Int> {
        var result = Set<Int>()
        var stack = [cluster]

        while let current = stack.popLast() {
            if current < n {
                result.insert(current)
            } else if let (left, right) = children[current] {
                stack.append(left)
                stack.append(right)
            }
        }

        return result
    }
}
