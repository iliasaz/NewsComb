import Accelerate
import Foundation
import OSLog

/// Vantage-Point tree for efficient k-nearest-neighbor (kNN) search in metric spaces.
///
/// A VP-tree recursively partitions data by distance to a chosen "vantage point",
/// enabling sub-linear kNN queries by pruning branches that cannot contain closer
/// neighbors than the current best set.
///
/// After PCA reduces vectors to ~50 dimensions, VP-trees provide O(N log N) kNN
/// construction, which is dramatically faster than the brute-force O(N²D) approach.
final class VPTreeService: Sendable {

    /// Distance metric for kNN search.
    enum Metric {
        case cosine
        case euclidean
    }

    /// A neighbor found during kNN search.
    struct Neighbor {
        let index: Int
        let distance: Float
    }

    /// Result of kNN search for all points.
    struct KNNResult {
        /// For each point i, the k nearest neighbor indices.
        let indices: [[Int]]
        /// For each point i, the corresponding distances.
        let distances: [[Float]]
    }

    private let logger = Logger(subsystem: "com.newscomb", category: "VPTreeService")

    // MARK: - Public API

    /// Computes k-nearest neighbors for all points using a VP-tree.
    ///
    /// - Parameters:
    ///   - vectors: Array of N vectors, each of dimension D.
    ///   - k: Number of neighbors to find per point.
    ///   - metric: Distance metric to use.
    /// - Returns: A `KNNResult` with indices and distances for each point.
    func findAllKNN(vectors: [[Float]], k: Int, metric: Metric = .cosine) async -> KNNResult {
        let n = vectors.count
        guard n > 1 else {
            return KNNResult(indices: Array(repeating: [], count: n),
                             distances: Array(repeating: [], count: n))
        }

        let effectiveK = min(k, n - 1)
        let d = vectors[0].count

        // For D >= 20, use vectorized brute-force via Accelerate's matrix multiply.
        // VP-trees prune poorly in high dimensions (most branches get visited),
        // while vDSP_mmul leverages the AMX coprocessor for massive throughput.
        if d >= 20 && metric == .cosine {
            logger.info("Vectorized kNN: n=\(n), d=\(d), k=\(effectiveK)")
            return vectorizedCosineKNN(vectors: vectors, k: effectiveK)
        }

        logger.info("VP-tree kNN: n=\(n), k=\(effectiveK), metric=\(String(describing: metric))")
        let startTime = ContinuousClock.now

        // Build the VP-tree
        let distanceFunc = makeDistanceFunction(metric: metric)
        let indices = Array(0..<n)
        let tree = buildTree(indices: indices, vectors: vectors, distanceFunc: distanceFunc)
        logger.info("VP-tree built in \(ContinuousClock.now - startTime)")

        // Query all points in parallel
        let searchContext = SearchContext(
            tree: tree, vectors: vectors, distanceFunc: distanceFunc, k: effectiveK
        )

        let coreCount = ProcessInfo.processInfo.activeProcessorCount
        let chunkSize = max(1, n / (coreCount * 2))

        let results = await withTaskGroup(
            of: (start: Int, indices: [[Int]], distances: [[Float]]).self
        ) { group in
            for chunkStart in stride(from: 0, to: n, by: chunkSize) {
                let chunkEnd = min(chunkStart + chunkSize, n)

                group.addTask { @concurrent in
                    var chunkIndices: [[Int]] = []
                    var chunkDistances: [[Float]] = []
                    chunkIndices.reserveCapacity(chunkEnd - chunkStart)
                    chunkDistances.reserveCapacity(chunkEnd - chunkStart)

                    for i in chunkStart..<chunkEnd {
                        let neighbors = Self.searchTree(
                            context: searchContext, queryIndex: i
                        )
                        chunkIndices.append(neighbors.map(\.index))
                        chunkDistances.append(neighbors.map(\.distance))
                    }
                    return (start: chunkStart, indices: chunkIndices, distances: chunkDistances)
                }
            }

            var allIndices: [[Int]] = Array(repeating: [], count: n)
            var allDistances: [[Float]] = Array(repeating: [], count: n)

            for await (start, chunkIndices, chunkDistances) in group {
                for (offset, idx) in chunkIndices.enumerated() {
                    allIndices[start + offset] = idx
                    allDistances[start + offset] = chunkDistances[offset]
                }
            }

            return KNNResult(indices: allIndices, distances: allDistances)
        }

        let elapsed = ContinuousClock.now - startTime
        logger.info("VP-tree kNN complete: \(n) queries × k=\(effectiveK) in \(elapsed) (\(coreCount) cores)")

        return results
    }

    // MARK: - Vectorized Brute-Force kNN

    /// Computes k-nearest neighbors using Accelerate matrix multiply.
    ///
    /// For cosine distance on normalized vectors, similarity = dot product.
    /// Computes the full similarity matrix in tiles using `vDSP_mmul` (which
    /// leverages the AMX coprocessor on Apple Silicon), then extracts top-k
    /// per row using a streaming insertion-sort heap.
    ///
    /// At N=89K, D=50: ~3-5 seconds total vs ~15 minutes with VP-tree.
    private func vectorizedCosineKNN(vectors: [[Float]], k: Int) -> KNNResult {
        let n = vectors.count
        let d = vectors[0].count
        let startTime = ContinuousClock.now

        // Step 1: Flatten and L2-normalize all vectors.
        // For normalized vectors, cosine_similarity = dot_product,
        // so cosine_distance = 1 - dot_product.
        var flat = [Float](repeating: 0, count: n * d)
        for i in 0..<n {
            let normalized = AccelerateVectorOps.normalize(vectors[i])
            flat.replaceSubrange((i * d)..<((i + 1) * d), with: normalized)
        }
        logger.info("Vectorized kNN: step 1 normalized \(n) vectors in \(ContinuousClock.now - startTime)")

        // Step 2: Compute similarity matrix in tiles to limit memory usage.
        // Each tile: Q queries × N targets = Q×N floats.
        // Tile size chosen to keep memory ~400MB per tile.
        let tileSize = max(1, min(n, 400_000_000 / (n * 4)))

        // Transpose of full matrix for vDSP_mmul: B = flatᵀ (D×N)
        var flatTransposed = [Float](repeating: 0, count: d * n)
        vDSP_mtrans(flat, 1, &flatTransposed, 1, vDSP_Length(d), vDSP_Length(n))
        logger.info("Vectorized kNN: step 2 transposed in \(ContinuousClock.now - startTime)")

        // Process tiles and extract top-k
        var allIndices: [[Int]] = Array(repeating: [], count: n)
        var allDistances: [[Float]] = Array(repeating: [], count: n)

        for tileStart in stride(from: 0, to: n, by: tileSize) {
            let tileEnd = min(tileStart + tileSize, n)
            let q = tileEnd - tileStart

            // Compute Q×N similarity matrix: S = queries[Q×D] × flatᵀ[D×N]
            var similarities = [Float](repeating: 0, count: q * n)
            flat.withUnsafeBufferPointer { flatBuf in
                vDSP_mmul(
                    flatBuf.baseAddress! + tileStart * d, 1,
                    flatTransposed, 1,
                    &similarities, 1,
                    vDSP_Length(q),
                    vDSP_Length(n),
                    vDSP_Length(d)
                )
            }
            logger.info("Vectorized kNN: step 2 tile \(tileStart/tileSize + 1) mmul (\(q)×\(n)) in \(ContinuousClock.now - startTime)")

            // Step 3: Extract top-k per row using pointer-based streaming heap.
            // This is the hot loop — operates directly on contiguous memory
            // with a fixed-size sorted buffer (insertion sort at k=15 is fast).
            similarities.withUnsafeMutableBufferPointer { simBuf in
                for qi in 0..<q {
                    let globalI = tileStart + qi
                    let row = simBuf.baseAddress! + qi * n

                    // Exclude self-similarity
                    row[globalI] = -.infinity

                    // Fixed-size sorted buffer for top-k (descending by similarity).
                    // At k=15, insertion sort into a 15-element array is faster than
                    // any heap structure due to cache locality and branch prediction.
                    var topIndices = [Int](repeating: 0, count: k)
                    var topSims = [Float](repeating: -.infinity, count: k)

                    for j in 0..<n {
                        let sim = row[j]
                        // Quick reject: skip if worse than current k-th best
                        if sim <= topSims[k - 1] { continue }

                        // Insertion sort into the sorted buffer
                        var pos = k - 1
                        while pos > 0 && sim > topSims[pos - 1] {
                            topSims[pos] = topSims[pos - 1]
                            topIndices[pos] = topIndices[pos - 1]
                            pos -= 1
                        }
                        topSims[pos] = sim
                        topIndices[pos] = j
                    }

                    allIndices[globalI] = topIndices
                    allDistances[globalI] = topSims.map { 1.0 - $0 }
                }
            }
            logger.info("Vectorized kNN: step 3 tile top-k extracted in \(ContinuousClock.now - startTime)")
        }

        let elapsed = ContinuousClock.now - startTime
        logger.info("Vectorized kNN complete: \(n) × k=\(k) in \(elapsed)")

        return KNNResult(indices: allIndices, distances: allDistances)
    }

    // MARK: - Search Context (for concurrent queries)

    /// Read-only context passed to concurrent kNN query tasks.
    /// Uses `nonisolated(unsafe)` because the tree and vectors are never mutated
    /// after construction — they're built once then queried in parallel.
    private struct SearchContext: @unchecked Sendable {
        let tree: VPNode?
        let vectors: [[Float]]
        let distanceFunc: @Sendable ([Float], [Float]) -> Float
        let k: Int
    }

    /// Static search method that takes an explicit context — avoids capturing `self`
    /// in concurrent task closures (which would require Sendable proof for the actor).
    private static func searchTree(context: SearchContext, queryIndex: Int) -> [Neighbor] {
        guard let root = context.tree else { return [] }
        var heap = BoundedMaxHeap(capacity: context.k)
        var stack: [VPNode] = [root]

        while let node = stack.popLast() {
            let dist = context.distanceFunc(context.vectors[queryIndex], context.vectors[node.pointIndex])

            if node.pointIndex != queryIndex {
                heap.insert(Neighbor(index: node.pointIndex, distance: dist))
            }

            if dist <= node.radius {
                if let right = node.right, dist + heap.maxDistance > node.radius {
                    stack.append(right)
                }
                if let left = node.left, dist - heap.maxDistance <= node.radius {
                    stack.append(left)
                }
            } else {
                if let left = node.left, dist - heap.maxDistance <= node.radius {
                    stack.append(left)
                }
                if let right = node.right, dist + heap.maxDistance > node.radius {
                    stack.append(right)
                }
            }
        }

        return heap.sorted()
    }

    // MARK: - VP-Tree Node

    /// A node in the VP-tree. Either a leaf (single point) or an internal node
    /// that partitions children by distance to its vantage point.
    private final class VPNode: Sendable {
        let pointIndex: Int
        let radius: Float
        let left: VPNode?   // points with distance <= radius
        let right: VPNode?  // points with distance > radius

        init(pointIndex: Int, radius: Float = 0, left: VPNode? = nil, right: VPNode? = nil) {
            self.pointIndex = pointIndex
            self.radius = radius
            self.left = left
            self.right = right
        }
    }

    // MARK: - Tree Construction

    /// Builds a VP-tree from the given point indices.
    private func buildTree(indices: [Int], vectors: [[Float]],
                           distanceFunc: @Sendable ([Float], [Float]) -> Float) -> VPNode? {
        guard !indices.isEmpty else { return nil }
        if indices.count == 1 {
            return VPNode(pointIndex: indices[0])
        }

        // Choose the vantage point (first element; random selection is also common)
        let vpIndex = indices[0]
        let remaining = Array(indices.dropFirst())

        // Compute distances from the vantage point to all remaining points
        var distancePairs = remaining.map { idx in
            (index: idx, distance: distanceFunc(vectors[vpIndex], vectors[idx]))
        }

        // Find the median distance to partition
        distancePairs.sort { $0.distance < $1.distance }
        let medianIdx = distancePairs.count / 2
        let radius = distancePairs[medianIdx].distance

        // Partition: left (close), right (far). Use median+1 for right to guarantee
        // progress — if all distances are equal, the split still reduces both sides.
        let splitIdx = max(1, medianIdx) // Ensure left is non-empty
        let leftIndices = distancePairs[..<splitIdx].map(\.index)
        let rightIndices = distancePairs[splitIdx...].map(\.index)

        let left = buildTree(indices: leftIndices, vectors: vectors, distanceFunc: distanceFunc)
        let right = buildTree(indices: rightIndices, vectors: vectors, distanceFunc: distanceFunc)

        return VPNode(pointIndex: vpIndex, radius: radius, left: left, right: right)
    }

    // MARK: - kNN Search

    /// Searches the VP-tree for the k nearest neighbors of a query point.
    ///
    /// Uses an iterative traversal with an explicit stack (avoiding stack overflow
    /// on deep trees) and a bounded max-heap of the current best k neighbors.
    /// Prunes branches whose closest possible point is farther than the
    /// current k-th nearest distance.
    private func knnSearch(tree: VPNode?, query: [Float], queryIndex: Int,
                           k: Int, vectors: [[Float]],
                           distanceFunc: @Sendable ([Float], [Float]) -> Float) -> [Neighbor] {
        guard let root = tree else { return [] }

        var heap = BoundedMaxHeap(capacity: k)
        var stack: [VPNode] = [root]

        while let node = stack.popLast() {
            let dist = distanceFunc(query, vectors[node.pointIndex])

            // Don't include the query point itself as its own neighbor
            if node.pointIndex != queryIndex {
                heap.insert(Neighbor(index: node.pointIndex, distance: dist))
            }

            // Decide which subtree(s) to search.
            // Push the less-promising subtree first so the more-promising one
            // is popped (and searched) first — this tightens tau faster.
            if dist <= node.radius {
                // Query is inside the radius — prefer left (close) subtree
                if let right = node.right, dist + heap.maxDistance > node.radius {
                    stack.append(right)
                }
                if let left = node.left, dist - heap.maxDistance <= node.radius {
                    stack.append(left)
                }
            } else {
                // Query is outside the radius — prefer right (far) subtree
                if let left = node.left, dist - heap.maxDistance <= node.radius {
                    stack.append(left)
                }
                if let right = node.right, dist + heap.maxDistance > node.radius {
                    stack.append(right)
                }
            }
        }

        return heap.sorted()
    }

    // MARK: - Bounded Max-Heap

    /// A simple bounded max-heap for maintaining the k closest neighbors.
    ///
    /// Stores at most `capacity` neighbors, always evicting the farthest
    /// when a closer one is found.
    private struct BoundedMaxHeap {
        let capacity: Int
        private var items: [Neighbor] = []

        var maxDistance: Float {
            items.count < capacity ? Float.infinity : (items.last?.distance ?? .infinity)
        }

        init(capacity: Int) {
            self.capacity = capacity
            items.reserveCapacity(capacity + 1)
        }

        mutating func insert(_ neighbor: Neighbor) {
            if items.count < capacity || neighbor.distance < maxDistance {
                // Binary search for insertion position (maintain sorted ascending order)
                let insertIdx = binarySearchInsertionIndex(for: neighbor.distance)
                items.insert(neighbor, at: insertIdx)
                if items.count > capacity {
                    items.removeLast()
                }
            }
        }

        /// Binary search for the insertion index to maintain ascending distance order.
        private func binarySearchInsertionIndex(for distance: Float) -> Int {
            var lo = 0
            var hi = items.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if items[mid].distance < distance {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            return lo
        }

        /// Returns neighbors sorted by distance (ascending).
        func sorted() -> [Neighbor] {
            items
        }
    }

    // MARK: - Distance Functions

    /// Creates a distance function for the given metric.
    private func makeDistanceFunction(metric: Metric) -> @Sendable ([Float], [Float]) -> Float {
        switch metric {
        case .cosine:
            return { a, b in
                Self.cosineDistance(a, b)
            }
        case .euclidean:
            return { a, b in
                AccelerateVectorOps.l2Distance(a, b)
            }
        }
    }

    /// Cosine distance: 1 - cosine_similarity.
    private static func cosineDistance(_ a: [Float], _ b: [Float]) -> Float {
        1.0 - AccelerateVectorOps.cosineSimilarity(a, b)
    }
}
