import XCTest
@testable import NewsCombApp

final class LongestPathFinderTests: XCTestCase {

    // MARK: - Helpers

    private func node(_ id: Int64) -> GraphNode {
        GraphNode(id: id, label: "Node \(id)", nodeType: nil)
    }

    private func edge(_ id: Int64, from: Int64, to: Int64) -> GraphEdge {
        GraphEdge(
            id: id,
            edgeId: "e\(id)",
            label: "rel",
            sourceNodeIds: [from],
            targetNodeIds: [to]
        )
    }

    // MARK: - Edge Cases

    func testEmptyGraphReturnsNoPaths() {
        let result = LongestPathFinder.topLongestPaths(nodes: [], edges: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testGraphWithNoEdgesReturnsNoPaths() {
        let nodes = [node(1), node(2)]
        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: [])
        XCTAssertTrue(result.isEmpty)
    }

    func testZeroCountReturnsNoPaths() {
        let nodes = [node(1), node(2)]
        let edges = [edge(1, from: 1, to: 2)]
        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: edges, count: 0)
        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - Correctness

    func testSimpleChainProducesFullPath() {
        // 1 -- 2 -- 3 -- 4 -- 5
        let nodes = (1...5).map { node(Int64($0)) }
        let edges = [
            edge(1, from: 1, to: 2),
            edge(2, from: 2, to: 3),
            edge(3, from: 3, to: 4),
            edge(4, from: 4, to: 5)
        ]

        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: edges, count: 1)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].count, 5, "Longest path should traverse all 5 nodes")
        XCTAssertEqual(Set(result[0]), Set([1, 2, 3, 4, 5]))
    }

    func testEdgesAreTreatedAsUndirected() {
        // Direction shouldn't matter: a -> b -> c should still find a path of 3.
        let nodes = [node(1), node(2), node(3)]
        let edges = [
            edge(1, from: 1, to: 2),
            edge(2, from: 3, to: 2)  // reversed direction at 3
        ]

        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: edges, count: 1)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].count, 3)
    }

    func testReturnsSortedDescending() {
        // Two disconnected components: a chain of 4 and a chain of 2.
        let nodes = (1...6).map { node(Int64($0)) }
        let edges = [
            edge(1, from: 1, to: 2),
            edge(2, from: 2, to: 3),
            edge(3, from: 3, to: 4),
            edge(4, from: 5, to: 6)
        ]

        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: edges, count: 5)

        XCTAssertGreaterThanOrEqual(result.count, 2)
        for i in 1..<result.count {
            XCTAssertGreaterThanOrEqual(
                result[i - 1].count,
                result[i].count,
                "Paths must be sorted longest-first"
            )
        }
    }

    func testRespectsMaxDepth() {
        // Chain of 10, but we cap depth at 4.
        let nodes = (1...10).map { node(Int64($0)) }
        let edges = (1..<10).map { i in edge(Int64(i), from: Int64(i), to: Int64(i + 1)) }

        let result = LongestPathFinder.topLongestPaths(
            nodes: nodes,
            edges: edges,
            count: 1,
            maxDepth: 4
        )

        XCTAssertEqual(result.count, 1)
        XCTAssertLessThanOrEqual(result[0].count, 4)
    }

    func testDoesNotRevisitNodesInPath() {
        // Triangle: any path can have at most 3 nodes (no repeats).
        let nodes = [node(1), node(2), node(3)]
        let edges = [
            edge(1, from: 1, to: 2),
            edge(2, from: 2, to: 3),
            edge(3, from: 3, to: 1)
        ]

        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: edges, count: 1)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].count, 3)
        XCTAssertEqual(Set(result[0]).count, 3, "No node should appear twice in a simple path")
    }

    func testHyperedgeConnectsAllSourcesToAllTargets() {
        // Hyperedge with sources {1,2} and targets {3,4} creates 4 pairs:
        // (1,3) (1,4) (2,3) (2,4). A long simple path should exist using
        // these pairs across all four nodes.
        let nodes = [node(1), node(2), node(3), node(4)]
        let hyperedge = GraphEdge(
            id: 1,
            edgeId: "h1",
            label: "rel",
            sourceNodeIds: [1, 2],
            targetNodeIds: [3, 4]
        )

        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: [hyperedge], count: 1)

        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].count, 4, "All 4 nodes should be reachable via the hyperedge")
    }

    func testDeduplicatesPathsWithSameNodeSet() {
        // Triangle 1-2-3 has paths [1,2,3], [2,3,1], [3,1,2] etc.
        // All share the same node-set; only one should be returned.
        let nodes = [node(1), node(2), node(3)]
        let edges = [
            edge(1, from: 1, to: 2),
            edge(2, from: 2, to: 3),
            edge(3, from: 3, to: 1)
        ]

        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: edges, count: 10)

        XCTAssertEqual(result.count, 1, "Identical node-sets should be deduplicated")
    }

    func testCountLimitsResults() {
        // Build several disjoint chains of varying lengths.
        var nodes: [GraphNode] = []
        var edges: [GraphEdge] = []
        var nextId: Int64 = 1
        var nextEdgeId: Int64 = 1
        for length in 2...6 {
            let start = nextId
            for offset in 0..<length {
                nodes.append(node(start + Int64(offset)))
            }
            for offset in 0..<(length - 1) {
                edges.append(edge(
                    nextEdgeId,
                    from: start + Int64(offset),
                    to: start + Int64(offset + 1)
                ))
                nextEdgeId += 1
            }
            nextId += Int64(length)
        }

        let result = LongestPathFinder.topLongestPaths(nodes: nodes, edges: edges, count: 3)

        XCTAssertLessThanOrEqual(result.count, 3)
    }
}
