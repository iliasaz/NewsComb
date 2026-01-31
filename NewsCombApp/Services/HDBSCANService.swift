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

    /// Configuration parameters for HDBSCAN.
    struct Parameters {
        /// Minimum number of points to form a cluster.
        var minClusterSize: Int = 20
        /// Number of neighbors for core distance computation.
        var minSamples: Int = 10

        /// Validates and adjusts parameters for the data size.
        func validated(forDataSize n: Int) -> Parameters {
            var p = self
            p.minClusterSize = min(p.minClusterSize, max(2, n / 5))
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
        logger.info("Running HDBSCAN: n=\(n), minClusterSize=\(params.minClusterSize), minSamples=\(params.minSamples)")

        // Step 1: Compute pairwise distances and core distances
        let distances = computeDistanceMatrix(vectors)
        let coreDistances = computeCoreDistances(distances: distances, minSamples: params.minSamples)

        // Step 2: Build MST on mutual reachability graph
        let mst = buildMST(distances: distances, coreDistances: coreDistances, n: n)

        // Step 3: Build condensed cluster tree
        let treeInfo = buildCondensedTree(mst: mst, n: n, minClusterSize: params.minClusterSize)

        // Step 4: Select clusters via EOM
        let (labels, memberships, clusterCount) = selectClusters(treeInfo: treeInfo)

        logger.info("HDBSCAN found \(clusterCount) clusters with \(labels.filter { $0 == -1 }.count) noise points")
        return ClusterResult(labels: labels, memberships: memberships, clusterCount: clusterCount)
    }

    // MARK: - Step 1: Distance Matrix & Core Distances

    /// Computes the full NxN Euclidean distance matrix using Accelerate.
    private func computeDistanceMatrix(_ vectors: [[Float]]) -> [Float] {
        let n = vectors.count
        guard let dim = vectors.first?.count else { return [] }

        // Flatten vectors
        var flat = [Float](repeating: 0, count: n * dim)
        for i in 0..<n {
            flat.replaceSubrange((i * dim)..<((i + 1) * dim), with: vectors[i])
        }

        // Compute ||a||² for each vector
        var norms = [Float](repeating: 0, count: n)
        for i in 0..<n {
            var normSq: Float = 0
            vDSP_svesq(Array(flat[(i * dim)..<((i + 1) * dim)]), 1, &normSq, vDSP_Length(dim))
            norms[i] = normSq
        }

        // Compute dot products: A * A^T
        var dots = [Float](repeating: 0, count: n * n)
        cblas_sgemm(
            CblasRowMajor, CblasNoTrans, CblasTrans,
            Int32(n), Int32(n), Int32(dim),
            1.0, flat, Int32(dim),
            flat, Int32(dim),
            0.0, &dots, Int32(n)
        )

        // dist²(a,b) = ||a||² + ||b||² - 2*(a·b)
        var distances = [Float](repeating: 0, count: n * n)
        for i in 0..<n {
            for j in 0..<n {
                if i == j {
                    distances[i * n + j] = 0
                } else {
                    let d2 = max(0, norms[i] + norms[j] - 2 * dots[i * n + j])
                    distances[i * n + j] = sqrt(d2)
                }
            }
        }

        return distances
    }

    /// Computes core distance for each point (distance to the k-th nearest neighbor).
    private func computeCoreDistances(distances: [Float], minSamples: Int) -> [Float] {
        let n = Int(sqrt(Double(distances.count)))
        var coreDistances = [Float](repeating: 0, count: n)

        for i in 0..<n {
            // Extract row i distances and sort
            var rowDists = [Float](repeating: 0, count: n)
            for j in 0..<n {
                rowDists[j] = distances[i * n + j]
            }
            rowDists.sort()

            // Core distance = distance to k-th nearest neighbor (index minSamples)
            let k = min(minSamples, n - 1)
            coreDistances[i] = rowDists[k]
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

        for _ in 1..<n {
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
