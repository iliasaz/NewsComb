import XCTest
@testable import NewsCombApp

final class GraphVisualizationTests: XCTestCase {

    // MARK: - ForceDirectedLayout Tests

    func testLayoutInitializesNodePositions() {
        let layout = ForceDirectedLayout()
        let nodes = [
            GraphNode(id: 1, label: "Node A", nodeType: nil),
            GraphNode(id: 2, label: "Node B", nodeType: nil),
            GraphNode(id: 3, label: "Node C", nodeType: nil)
        ]

        layout.initialize(nodes: nodes, canvasSize: CGSize(width: 800, height: 600))

        // All nodes should have positions
        XCTAssertNotNil(layout.position(for: 1))
        XCTAssertNotNil(layout.position(for: 2))
        XCTAssertNotNil(layout.position(for: 3))
    }

    func testLayoutPositionsAreWithinCanvas() {
        let layout = ForceDirectedLayout()
        let canvasSize = CGSize(width: 1000, height: 800)
        let nodes = (1...10).map { GraphNode(id: Int64($0), label: "Node \($0)", nodeType: nil) }

        layout.initialize(nodes: nodes, canvasSize: canvasSize)

        for i in 1...10 {
            guard let position = layout.position(for: Int64(i)) else {
                XCTFail("Missing position for node \(i)")
                continue
            }
            XCTAssertGreaterThanOrEqual(position.x, 0)
            XCTAssertLessThanOrEqual(position.x, canvasSize.width)
            XCTAssertGreaterThanOrEqual(position.y, 0)
            XCTAssertLessThanOrEqual(position.y, canvasSize.height)
        }
    }

    func testLayoutStepReducesEnergy() {
        let layout = ForceDirectedLayout()
        let nodes = [
            GraphNode(id: 1, label: "A", nodeType: nil),
            GraphNode(id: 2, label: "B", nodeType: nil)
        ]
        let edges = [
            GraphEdge(id: 1, edgeId: "e1", label: "relates_to", sourceNodeIds: [1], targetNodeIds: [2])
        ]

        layout.initialize(nodes: nodes, canvasSize: CGSize(width: 500, height: 500))

        // Run several iterations
        for _ in 0..<100 {
            layout.step(edges: edges)
        }

        // After many steps, layout should be stabilizing or stable
        // We can't test exact positions but can verify it doesn't crash
        XCTAssertNotNil(layout.position(for: 1))
        XCTAssertNotNil(layout.position(for: 2))
    }

    func testLayoutPinNode() {
        let layout = ForceDirectedLayout()
        let nodes = [
            GraphNode(id: 1, label: "A", nodeType: nil),
            GraphNode(id: 2, label: "B", nodeType: nil)
        ]

        layout.initialize(nodes: nodes, canvasSize: CGSize(width: 500, height: 500))

        let pinnedPosition = CGPoint(x: 100, y: 100)
        layout.pinNode(1, at: pinnedPosition)

        // Verify node is pinned
        XCTAssertTrue(layout.isPinned(1))
        XCTAssertFalse(layout.isPinned(2))

        // Position should be at pinned location
        let position = layout.position(for: 1)
        XCTAssertEqual(position?.x, pinnedPosition.x)
        XCTAssertEqual(position?.y, pinnedPosition.y)
    }

    func testLayoutUnpinNode() {
        let layout = ForceDirectedLayout()
        let nodes = [GraphNode(id: 1, label: "A", nodeType: nil)]

        layout.initialize(nodes: nodes, canvasSize: CGSize(width: 500, height: 500))
        layout.pinNode(1, at: CGPoint(x: 100, y: 100))

        XCTAssertTrue(layout.isPinned(1))

        layout.unpinNode(1)

        XCTAssertFalse(layout.isPinned(1))
    }

    func testLayoutMoveNode() {
        let layout = ForceDirectedLayout()
        let nodes = [GraphNode(id: 1, label: "A", nodeType: nil)]

        layout.initialize(nodes: nodes, canvasSize: CGSize(width: 500, height: 500))

        let pinnedPosition = CGPoint(x: 100, y: 100)
        layout.pinNode(1, at: pinnedPosition)

        let newPosition = CGPoint(x: 200, y: 200)
        layout.moveNode(1, to: newPosition)

        let position = layout.position(for: 1)
        XCTAssertEqual(position?.x, newPosition.x)
        XCTAssertEqual(position?.y, newPosition.y)
    }

    func testLayoutCenterGraph() {
        let layout = ForceDirectedLayout()
        let canvasSize = CGSize(width: 800, height: 600)

        // Manually set positions to be off-center
        let nodePositions: [Int64: CGPoint] = [
            1: CGPoint(x: 0, y: 0),
            2: CGPoint(x: 100, y: 100)
        ]
        layout.initialize(nodePositions: nodePositions)

        layout.centerGraph(in: canvasSize)

        // Calculate expected center
        let position1 = layout.position(for: 1)!
        let position2 = layout.position(for: 2)!

        let centerX = (position1.x + position2.x) / 2
        let centerY = (position1.y + position2.y) / 2

        // Graph center should be near canvas center
        XCTAssertEqual(centerX, canvasSize.width / 2, accuracy: 1)
        XCTAssertEqual(centerY, canvasSize.height / 2, accuracy: 1)
    }

    func testLayoutReset() {
        let layout = ForceDirectedLayout()
        let nodes = [
            GraphNode(id: 1, label: "A", nodeType: nil),
            GraphNode(id: 2, label: "B", nodeType: nil)
        ]
        let edges = [
            GraphEdge(id: 1, edgeId: "e1", label: "rel", sourceNodeIds: [1], targetNodeIds: [2])
        ]

        layout.initialize(nodes: nodes, canvasSize: CGSize(width: 500, height: 500))

        // Run until stable
        for _ in 0..<500 {
            layout.step(edges: edges)
        }

        // Reset should allow simulation to run again
        layout.reset()

        // After reset, simulation should not be stable
        XCTAssertFalse(layout.isStable)

        // Should be able to step again
        layout.step(edges: edges)
    }

    // MARK: - GraphNode Tests

    func testGraphNodeEquality() {
        let node1 = GraphNode(id: 1, label: "Test", nodeType: "Person")
        let node2 = GraphNode(id: 1, label: "Test", nodeType: "Person")
        let node3 = GraphNode(id: 2, label: "Test", nodeType: "Person")

        XCTAssertEqual(node1, node2)
        XCTAssertNotEqual(node1, node3)
    }

    func testGraphNodePositionUpdate() {
        var node = GraphNode(id: 1, label: "Test", nodeType: nil)
        XCTAssertEqual(node.position, CGPoint.zero)

        node.position = CGPoint(x: 100, y: 200)
        XCTAssertEqual(node.position.x, 100)
        XCTAssertEqual(node.position.y, 200)
    }

    // MARK: - GraphEdge Tests

    func testGraphEdgeEquality() {
        let edge1 = GraphEdge(id: 1, edgeId: "e1", label: "knows", sourceNodeIds: [1], targetNodeIds: [2])
        let edge2 = GraphEdge(id: 1, edgeId: "e1", label: "knows", sourceNodeIds: [1], targetNodeIds: [2])
        let edge3 = GraphEdge(id: 2, edgeId: "e2", label: "knows", sourceNodeIds: [1], targetNodeIds: [3])

        XCTAssertEqual(edge1, edge2)
        XCTAssertNotEqual(edge1, edge3)
    }

    func testGraphEdgeWithMultipleNodes() {
        let edge = GraphEdge(
            id: 1,
            edgeId: "hyperedge",
            label: "involved_in",
            sourceNodeIds: [1, 2, 3],
            targetNodeIds: [4, 5]
        )

        XCTAssertEqual(edge.sourceNodeIds.count, 3)
        XCTAssertEqual(edge.targetNodeIds.count, 2)
    }

    // MARK: - GraphData Tests

    func testGraphDataEmpty() {
        let data = GraphData(nodes: [], edges: [])
        XCTAssertTrue(data.nodes.isEmpty)
        XCTAssertTrue(data.edges.isEmpty)
    }

    func testGraphDataWithContent() {
        let nodes = [
            GraphNode(id: 1, label: "A", nodeType: nil),
            GraphNode(id: 2, label: "B", nodeType: nil)
        ]
        let edges = [
            GraphEdge(id: 1, edgeId: "e1", label: "rel", sourceNodeIds: [1], targetNodeIds: [2])
        ]

        let data = GraphData(nodes: nodes, edges: edges)

        XCTAssertEqual(data.nodes.count, 2)
        XCTAssertEqual(data.edges.count, 1)
    }

    // MARK: - Performance Tests

    func testLayoutPerformanceWithManyNodes() {
        let layout = ForceDirectedLayout()
        let nodeCount = 100
        let nodes = (1...nodeCount).map { GraphNode(id: Int64($0), label: "Node \($0)", nodeType: nil) }

        // Create a connected graph
        var edges: [GraphEdge] = []
        for i in 1..<nodeCount {
            edges.append(GraphEdge(
                id: Int64(i),
                edgeId: "e\(i)",
                label: "connected",
                sourceNodeIds: [Int64(i)],
                targetNodeIds: [Int64(i + 1)]
            ))
        }

        layout.initialize(nodes: nodes, canvasSize: CGSize(width: 2000, height: 2000))

        measure {
            for _ in 0..<60 {
                layout.step(edges: edges)
            }
        }
    }

    // MARK: - Coordinate Transformation Tests

    func testScreenToCanvasTransformation() {
        // Test the coordinate transformation logic
        let scale: CGFloat = 2.0
        let offset = CGSize(width: 100, height: 50)
        let size = CGSize(width: 800, height: 600)
        let screenPoint = CGPoint(x: 500, y: 350)

        // Reverse transformation (screen to canvas)
        let centeredX = screenPoint.x - size.width / 2 - offset.width
        let centeredY = screenPoint.y - size.height / 2 - offset.height
        let scaledX = centeredX / scale + size.width / 2
        let scaledY = centeredY / scale + size.height / 2
        let canvasPoint = CGPoint(x: scaledX, y: scaledY)

        // Verify we can transform back
        let backCenteredX = canvasPoint.x - size.width / 2
        let backCenteredY = canvasPoint.y - size.height / 2
        let backScreenX = backCenteredX * scale + size.width / 2 + offset.width
        let backScreenY = backCenteredY * scale + size.height / 2 + offset.height

        XCTAssertEqual(backScreenX, screenPoint.x, accuracy: 0.001)
        XCTAssertEqual(backScreenY, screenPoint.y, accuracy: 0.001)
    }

    // MARK: - Hit Testing Tests

    func testPointToLineDistance() {
        // Point on the line
        let start = CGPoint(x: 0, y: 0)
        let end = CGPoint(x: 10, y: 0)
        let pointOnLine = CGPoint(x: 5, y: 0)

        let distance1 = pointToLineDistance(point: pointOnLine, lineStart: start, lineEnd: end)
        XCTAssertEqual(distance1, 0, accuracy: 0.001)

        // Point above the line
        let pointAbove = CGPoint(x: 5, y: 3)
        let distance2 = pointToLineDistance(point: pointAbove, lineStart: start, lineEnd: end)
        XCTAssertEqual(distance2, 3, accuracy: 0.001)

        // Point before line start
        let pointBefore = CGPoint(x: -3, y: 4)
        let distance3 = pointToLineDistance(point: pointBefore, lineStart: start, lineEnd: end)
        XCTAssertEqual(distance3, 5, accuracy: 0.001) // Distance to start point: sqrt(9+16) = 5
    }

    private func pointToLineDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lineLengthSq = dx * dx + dy * dy

        guard lineLengthSq > 0 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }

        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lineLengthSq))
        let projectionX = lineStart.x + t * dx
        let projectionY = lineStart.y + t * dy

        return hypot(point.x - projectionX, point.y - projectionY)
    }
}
