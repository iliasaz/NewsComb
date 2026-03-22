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
    func findAllKNN(vectors: [[Float]], k: Int, metric: Metric = .cosine) -> KNNResult {
        let n = vectors.count
        guard n > 1 else {
            return KNNResult(indices: Array(repeating: [], count: n),
                             distances: Array(repeating: [], count: n))
        }

        let effectiveK = min(k, n - 1)
        logger.info("VP-tree kNN: n=\(n), k=\(effectiveK), metric=\(String(describing: metric))")
        let startTime = ContinuousClock.now

        // Build the VP-tree
        let distanceFunc = makeDistanceFunction(metric: metric)
        let indices = Array(0..<n)
        let tree = buildTree(indices: indices, vectors: vectors, distanceFunc: distanceFunc)

        // Query each point
        var allIndices: [[Int]] = Array(repeating: [], count: n)
        var allDistances: [[Float]] = Array(repeating: [], count: n)

        for i in 0..<n {
            let neighbors = knnSearch(tree: tree, query: vectors[i], queryIndex: i,
                                      k: effectiveK, vectors: vectors, distanceFunc: distanceFunc)
            allIndices[i] = neighbors.map(\.index)
            allDistances[i] = neighbors.map(\.distance)

            if (i + 1) % 10000 == 0 {
                let elapsed = ContinuousClock.now - startTime
                logger.info("VP-tree kNN progress: \(i + 1)/\(n) — \(elapsed)")
            }
        }

        let elapsed = ContinuousClock.now - startTime
        logger.info("VP-tree kNN complete: \(n) queries × k=\(effectiveK) in \(elapsed)")

        return KNNResult(indices: allIndices, distances: allDistances)
    }

    // MARK: - VP-Tree Node

    /// A node in the VP-tree. Either a leaf (single point) or an internal node
    /// that partitions children by distance to its vantage point.
    private final class VPNode {
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
