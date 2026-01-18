import Foundation
import Observation
import GRDB

/// ViewModel for the graph visualization view.
/// Manages graph data loading, layout computation, and interaction state.
@MainActor
@Observable
class GraphViewModel {

    // MARK: - Observable State

    /// All nodes in the graph
    var nodes: [GraphNode] = []

    /// All edges in the graph
    var edges: [GraphEdge] = []

    /// Loading state
    var isLoading = false

    /// Error message for display
    var errorMessage: String?

    /// Whether the layout simulation is running
    var isSimulating = false

    /// Currently selected edge ID for highlighting
    var selectedEdgeId: Int64?

    /// Currently hovered node ID for tooltip
    var hoveredNodeId: Int64?

    /// Currently hovered edge ID for tooltip
    var hoveredEdgeId: Int64?

    /// Connection threshold for filtering nodes (minimum degree to show)
    var connectionThreshold: Int = 1

    /// Maximum degree across all nodes (for slider range)
    var maxDegree: Int = 1

    /// Nodes that have been manually expanded (shown despite being below threshold)
    var expandedNodeIds: Set<Int64> = []

    /// Custom node color hex value
    var nodeColorHex: String = AppSettings.defaultGraphNodeColor

    // MARK: - Private State

    @ObservationIgnored
    private let graphDataService = GraphDataService()

    @ObservationIgnored
    private let database = Database.shared

    @ObservationIgnored
    private var layout = ForceDirectedLayout()

    @ObservationIgnored
    private var layoutTimer: Timer?

    @ObservationIgnored
    private var autoPauseTimer: Timer?

    @ObservationIgnored
    private var canvasSize: CGSize = CGSize(width: 1000, height: 800)

    /// Dictionary for O(1) node lookup by ID
    @ObservationIgnored
    private var nodeIndex: [Int64: Int] = [:]

    /// Frame counter for batched UI updates
    @ObservationIgnored
    private var frameCounter = 0

    /// Update SwiftUI state every N frames (reduces re-renders)
    private let uiUpdateInterval = 2

    /// Duration before auto-pause kicks in
    private let autoPauseDuration: TimeInterval = 3.0

    // MARK: - Computed Properties

    /// Nodes visible after applying threshold filter and expansions
    var visibleNodes: [GraphNode] {
        nodes.filter { $0.degree >= connectionThreshold || expandedNodeIds.contains($0.id) }
    }

    /// Set of visible node IDs for efficient lookups
    var visibleNodeIds: Set<Int64> {
        Set(visibleNodes.map(\.id))
    }

    /// Edges where all endpoints are visible
    var visibleEdges: [GraphEdge] {
        let visible = visibleNodeIds
        return edges.filter { edge in
            edge.sourceNodeIds.allSatisfy { visible.contains($0) } &&
            edge.targetNodeIds.allSatisfy { visible.contains($0) }
        }
    }

    // MARK: - Initialization

    init() {
        loadNodeColorSetting()
    }

    // MARK: - Graph Loading

    /// Load the full knowledge graph from the database.
    func loadGraph() {
        isLoading = true
        errorMessage = nil

        do {
            let data = try graphDataService.loadFullGraph()
            nodes = data.nodes
            edges = data.edges
            maxDegree = max(data.maxDegree, 1)
            expandedNodeIds.removeAll()

            // Calculate optimal threshold to show ~50 nodes
            connectionThreshold = calculateOptimalThreshold(targetCount: 50)

            // Build node index for O(1) lookup
            rebuildNodeIndex()

            if !nodes.isEmpty {
                // Initialize layout with random positions
                layout.initialize(nodes: nodes, canvasSize: canvasSize)

                // Apply initial positions to nodes
                updateNodePositionsFromLayout()

                // Start the layout animation
                startLayoutAnimation()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Calculate the minimum threshold that results in approximately targetCount visible nodes.
    private func calculateOptimalThreshold(targetCount: Int) -> Int {
        guard !nodes.isEmpty else { return 1 }

        // Sort degrees in descending order
        let sortedDegrees = nodes.map(\.degree).sorted(by: >)

        // If we have fewer nodes than target, show all
        if sortedDegrees.count <= targetCount {
            return 1
        }

        // Find the degree at the targetCount position
        // This will be our threshold (nodes with degree >= this will be shown)
        let thresholdDegree = sortedDegrees[targetCount - 1]

        // Return at least 1
        return max(thresholdDegree, 1)
    }

    /// Load a subgraph centered on a specific node.
    func loadNeighborhood(nodeId: Int64) {
        isLoading = true
        errorMessage = nil

        do {
            let data = try graphDataService.loadNeighborhood(nodeId: nodeId)
            nodes = data.nodes
            edges = data.edges
            maxDegree = max(data.maxDegree, 1)
            expandedNodeIds.removeAll()

            rebuildNodeIndex()

            if !nodes.isEmpty {
                layout.initialize(nodes: nodes, canvasSize: canvasSize)
                updateNodePositionsFromLayout()
                startLayoutAnimation()
            }
        } catch {
            errorMessage = error.localizedDescription
        }

        isLoading = false
    }

    /// Reload the graph data.
    func reloadGraph() {
        stopLayoutAnimation()
        loadGraph()
    }

    // MARK: - Node Index

    /// Rebuild the node ID to index mapping for O(1) lookups.
    private func rebuildNodeIndex() {
        nodeIndex.removeAll(keepingCapacity: true)
        for (index, node) in nodes.enumerated() {
            nodeIndex[node.id] = index
        }
    }

    // MARK: - Layout Animation

    /// Start the physics simulation animation.
    func startLayoutAnimation() {
        guard layoutTimer == nil else { return }

        isSimulating = true
        layout.reset()
        frameCounter = 0

        // Run at 30 FPS instead of 60 for better performance with large graphs
        layoutTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.stepLayout()
            }
        }

        // Start auto-pause timer
        startAutoPauseTimer()
    }

    /// Start the auto-pause timer.
    private func startAutoPauseTimer() {
        autoPauseTimer?.invalidate()
        autoPauseTimer = Timer.scheduledTimer(withTimeInterval: autoPauseDuration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.onAutoPause()
            }
        }
    }

    /// Called when auto-pause timer fires.
    private func onAutoPause() {
        stopLayoutAnimation()
        centerOnTopNodes()
    }

    /// Stop the physics simulation animation.
    func stopLayoutAnimation() {
        layoutTimer?.invalidate()
        layoutTimer = nil
        autoPauseTimer?.invalidate()
        autoPauseTimer = nil
        isSimulating = false
    }

    /// Toggle layout simulation on/off.
    func toggleSimulation() {
        if isSimulating {
            stopLayoutAnimation()
        } else {
            startLayoutAnimation()
        }
    }

    /// Perform a single layout step.
    private func stepLayout() {
        guard isSimulating else { return }

        layout.step(edges: edges)
        frameCounter += 1

        // Only update SwiftUI state every N frames to reduce re-renders
        if frameCounter % uiUpdateInterval == 0 {
            updateNodePositionsFromLayout()
        }

        // Stop animation if layout has stabilized
        if layout.isStable {
            // Final position update
            updateNodePositionsFromLayout()
            stopLayoutAnimation()
        }
    }

    /// Update node positions from the layout engine.
    private func updateNodePositionsFromLayout() {
        for i in nodes.indices {
            if let position = layout.position(for: nodes[i].id) {
                nodes[i].position = position
            }
        }
    }

    // MARK: - Node Lookup

    /// Get a node by ID (O(1) lookup).
    func node(id: Int64) -> GraphNode? {
        guard let index = nodeIndex[id], index < nodes.count else { return nil }
        return nodes[index]
    }

    /// Get the index of a node by ID (O(1) lookup).
    func nodeIndexFor(id: Int64) -> Int? {
        nodeIndex[id]
    }

    /// Get an edge by ID.
    func edge(id: Int64) -> GraphEdge? {
        edges.first { $0.id == id }
    }

    // MARK: - Node Interaction

    /// Pin a node at a position (for dragging).
    func pinNode(_ nodeId: Int64) {
        guard let node = node(id: nodeId) else { return }
        layout.pinNode(nodeId, at: node.position)
    }

    /// Unpin a node to resume physics.
    /// Note: Does not restart layout - user can manually restart via Play button if needed.
    func unpinNode(_ nodeId: Int64) {
        layout.unpinNode(nodeId)
    }

    /// Move a node to a new position while dragging.
    func moveNode(_ nodeId: Int64, to position: CGPoint) {
        layout.moveNode(nodeId, to: position)

        // Update the node's position in our array using O(1) lookup
        if let index = nodeIndex[nodeId] {
            nodes[index].position = position
        }
    }

    // MARK: - Selection

    /// Toggle selection of an edge.
    func toggleEdgeSelection(_ edgeId: Int64) {
        if selectedEdgeId == edgeId {
            selectedEdgeId = nil
        } else {
            selectedEdgeId = edgeId
        }
    }

    /// Clear any selection.
    func clearSelection() {
        selectedEdgeId = nil
        hoveredNodeId = nil
    }

    // MARK: - Canvas Size

    /// Update the canvas size for layout calculations.
    func updateCanvasSize(_ size: CGSize) {
        canvasSize = size
    }

    /// Center the graph in the current canvas.
    func centerGraph() {
        layout.centerGraph(in: canvasSize)
        updateNodePositionsFromLayout()
    }

    // MARK: - Layout Parameters

    /// Adjust the spring length (ideal edge distance).
    func setSpringLength(_ length: CGFloat) {
        layout.springLength = length
        layout.reset()
        if !isSimulating {
            startLayoutAnimation()
        }
    }

    /// Adjust the repulsion strength.
    func setRepulsionStrength(_ strength: CGFloat) {
        layout.repulsionStrength = strength
        layout.reset()
        if !isSimulating {
            startLayoutAnimation()
        }
    }

    // MARK: - Centering on Top Nodes

    /// Center the view on the highest-connection nodes.
    func centerOnTopNodes(count: Int = 5) {
        // Get top N nodes by degree
        let topNodes = nodes
            .sorted { $0.degree > $1.degree }
            .prefix(count)

        guard !topNodes.isEmpty else { return }

        // Calculate center of top nodes
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        for node in topNodes {
            sumX += node.position.x
            sumY += node.position.y
        }
        let centerX = sumX / CGFloat(topNodes.count)
        let centerY = sumY / CGFloat(topNodes.count)

        // Calculate offset to move this center to canvas center
        let canvasCenterX = canvasSize.width / 2
        let canvasCenterY = canvasSize.height / 2

        let offsetX = canvasCenterX - centerX
        let offsetY = canvasCenterY - centerY

        // Apply offset to layout
        layout.applyOffset(dx: offsetX, dy: offsetY)
        updateNodePositionsFromLayout()
    }

    // MARK: - Node Color Settings

    /// Load the node color setting from the database.
    private func loadNodeColorSetting() {
        do {
            if let setting = try database.read({ db in
                try AppSettings.filter(AppSettings.Columns.key == AppSettings.graphNodeColor).fetchOne(db)
            }) {
                nodeColorHex = setting.value
            }
        } catch {
            nodeColorHex = AppSettings.defaultGraphNodeColor
        }
    }

    /// Save the node color to the database.
    func saveNodeColor(_ hex: String) {
        nodeColorHex = hex
        do {
            try database.write { db in
                try db.execute(sql: """
                    INSERT INTO app_settings (key, value) VALUES (?, ?)
                    ON CONFLICT(key) DO UPDATE SET value = excluded.value
                """, arguments: [AppSettings.graphNodeColor, hex])
            }
        } catch {
            // Silently fail - color will reset on next load
        }
    }

    // MARK: - Node Expansion

    /// Expand a node to show its hidden neighbors.
    func expandNode(_ nodeId: Int64) {
        guard node(id: nodeId) != nil else { return }

        do {
            // Load neighbors that are currently hidden
            let neighbors = try graphDataService.loadNeighbors(nodeId: nodeId)

            // Find which neighbors are below threshold and not already visible
            var newNodeIds: [Int64] = []
            for neighbor in neighbors {
                // Check if this neighbor is below threshold and not expanded
                if neighbor.degree < connectionThreshold && !expandedNodeIds.contains(neighbor.id) {
                    // Need to find the node in our nodes array to get its actual degree
                    if let existingNode = self.node(id: neighbor.id) {
                        if existingNode.degree < connectionThreshold {
                            expandedNodeIds.insert(neighbor.id)
                            newNodeIds.append(neighbor.id)
                        }
                    }
                }
            }

            guard !newNodeIds.isEmpty else { return }

            // Position new nodes near the expanded node
            positionNewNodesNear(nodeId: nodeId, newNodeIds: newNodeIds)

            // Run partial layout for a short time
            startPartialLayout(pinExcept: newNodeIds, duration: 1.0)

        } catch {
            // Silently fail - expansion won't work
        }
    }

    /// Position newly expanded nodes near a parent node.
    private func positionNewNodesNear(nodeId: Int64, newNodeIds: [Int64]) {
        guard let parentNode = node(id: nodeId) else { return }

        let radius: CGFloat = 100
        let count = newNodeIds.count

        for (index, newId) in newNodeIds.enumerated() {
            // Spread new nodes in a circle around parent
            let angle = (2 * .pi * CGFloat(index)) / CGFloat(max(count, 1))
            let newPosition = CGPoint(
                x: parentNode.position.x + radius * cos(angle),
                y: parentNode.position.y + radius * sin(angle)
            )

            // Update position in layout
            if layout.position(for: newId) != nil {
                layout.moveNode(newId, to: newPosition)
            }

            // Update in nodes array
            if let nodeIndex = nodeIndex[newId] {
                nodes[nodeIndex].position = newPosition
            }
        }
    }

    /// Start a partial layout that only moves certain nodes.
    private func startPartialLayout(pinExcept nodeIds: [Int64], duration: TimeInterval) {
        // Pin all nodes except the new ones
        for node in nodes {
            if !nodeIds.contains(node.id) {
                layout.pinNode(node.id, at: node.position)
            }
        }

        // Start simulation
        startLayoutAnimation()

        // Schedule stop after duration
        Timer.scheduledTimer(withTimeInterval: duration, repeats: false) { [weak self] _ in
            Task { @MainActor in
                self?.stopLayoutAnimation()
                // Unpin all nodes
                for node in self?.nodes ?? [] {
                    self?.layout.unpinNode(node.id)
                }
            }
        }
    }
}
