import XCTest
@testable import NewsCombApp

/// Exercises `GraphViewModel.filterVisibleNodes`, the pure filter helper
/// that backs `visibleNodes`. Tested via the static API to avoid
/// instantiating the view model (which touches `Database.current`).
final class GraphViewModelFilterTests: XCTestCase {

    private func node(_ id: Int64, degree: Int = 0) -> GraphNode {
        var n = GraphNode(id: id, label: "Node \(id)", nodeType: nil)
        n.degree = degree
        return n
    }

    // MARK: - Threshold mode (default)

    func testThresholdModeRespectsMinDegree() {
        let nodes = [node(1, degree: 1), node(2, degree: 5), node(3, degree: 10)]

        let visible = GraphViewModel.filterVisibleNodes(
            nodes,
            showingMatchesOnly: false,
            showingLongestPathsOnly: false,
            matchedNodeIds: [],
            expandedNodeIds: [],
            longestPathNodeIds: [],
            connectionThreshold: 5
        )

        XCTAssertEqual(Set(visible.map(\.id)), Set([2, 3]))
    }

    func testThresholdModeIncludesExpandedBelowThreshold() {
        let nodes = [node(1, degree: 1), node(2, degree: 5)]

        let visible = GraphViewModel.filterVisibleNodes(
            nodes,
            showingMatchesOnly: false,
            showingLongestPathsOnly: false,
            matchedNodeIds: [],
            expandedNodeIds: [1],
            longestPathNodeIds: [],
            connectionThreshold: 5
        )

        // Node 1 is below threshold but is expanded → included.
        XCTAssertEqual(Set(visible.map(\.id)), Set([1, 2]))
    }

    // MARK: - Matches-only mode

    func testMatchesOnlyShowsMatchesAndExpandedUnion() {
        // Node 1 matches search (yellow), node 2 was expanded via double-click,
        // node 3 is unrelated (high degree but no match, no expansion).
        let nodes = [node(1, degree: 1), node(2, degree: 1), node(3, degree: 99)]

        let visible = GraphViewModel.filterVisibleNodes(
            nodes,
            showingMatchesOnly: true,
            showingLongestPathsOnly: false,
            matchedNodeIds: [1],
            expandedNodeIds: [2],
            longestPathNodeIds: [],
            connectionThreshold: 1
        )

        XCTAssertEqual(Set(visible.map(\.id)), Set([1, 2]))
    }

    func testMatchesOnlyIgnoresThreshold() {
        // High-degree node 3 must NOT appear when matches-only is on,
        // even though it would dominate threshold mode.
        let nodes = [node(1, degree: 1), node(2, degree: 1), node(3, degree: 99)]

        let visible = GraphViewModel.filterVisibleNodes(
            nodes,
            showingMatchesOnly: true,
            showingLongestPathsOnly: false,
            matchedNodeIds: [1],
            expandedNodeIds: [],
            longestPathNodeIds: [],
            connectionThreshold: 1
        )

        XCTAssertEqual(visible.map(\.id), [1])
    }

    func testMatchesOnlyWithNoMatchesAndNoExpansionsIsEmpty() {
        let nodes = [node(1, degree: 5), node(2, degree: 5)]

        let visible = GraphViewModel.filterVisibleNodes(
            nodes,
            showingMatchesOnly: true,
            showingLongestPathsOnly: false,
            matchedNodeIds: [],
            expandedNodeIds: [],
            longestPathNodeIds: [],
            connectionThreshold: 1
        )

        XCTAssertTrue(visible.isEmpty)
    }

    // MARK: - Mode precedence

    func testMatchesOnlyTakesPrecedenceOverLongestPaths() {
        // If both flags are accidentally set, matches-only wins
        // (matches both the precedence in `filterVisibleNodes` and the
        // mutual-exclusion guards in the toggle methods).
        let nodes = [node(1, degree: 1), node(2, degree: 1), node(3, degree: 1)]

        let visible = GraphViewModel.filterVisibleNodes(
            nodes,
            showingMatchesOnly: true,
            showingLongestPathsOnly: true,
            matchedNodeIds: [1],
            expandedNodeIds: [],
            longestPathNodeIds: [2, 3],
            connectionThreshold: 1
        )

        XCTAssertEqual(visible.map(\.id), [1])
    }

    func testLongestPathsModeIgnoresMatches() {
        let nodes = [node(1, degree: 1), node(2, degree: 1), node(3, degree: 1)]

        let visible = GraphViewModel.filterVisibleNodes(
            nodes,
            showingMatchesOnly: false,
            showingLongestPathsOnly: true,
            matchedNodeIds: [1],
            expandedNodeIds: [],
            longestPathNodeIds: [2, 3],
            connectionThreshold: 1
        )

        XCTAssertEqual(Set(visible.map(\.id)), Set([2, 3]))
    }
}
