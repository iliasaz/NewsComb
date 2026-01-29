import Foundation
import Accelerate

// MARK: - Quadtree for Barnes-Hut Approximation

/// A quadtree node for Barnes-Hut force approximation.
/// Reduces repulsion calculation from O(n²) to O(n log n).
private final class QuadTreeNode {
    var bounds: CGRect
    var centerOfMass: CGPoint = .zero
    var totalMass: Int = 0
    var nodeId: Int64? // Only set for leaf nodes containing a single node
    var children: [QuadTreeNode]? // NW, NE, SW, SE

    init(bounds: CGRect) {
        self.bounds = bounds
    }

    /// Insert a node into the quadtree.
    func insert(nodeId: Int64, position: CGPoint) {
        guard bounds.contains(position) else { return }

        // Update center of mass
        let newMass = totalMass + 1
        centerOfMass = CGPoint(
            x: (centerOfMass.x * CGFloat(totalMass) + position.x) / CGFloat(newMass),
            y: (centerOfMass.y * CGFloat(totalMass) + position.y) / CGFloat(newMass)
        )
        totalMass = newMass

        // If this is an empty leaf, store the node here
        if self.nodeId == nil && children == nil {
            self.nodeId = nodeId
            return
        }

        // If this was a leaf with a node, we need to subdivide
        if children == nil {
            subdivide()
            // Re-insert the existing node
            if let existingId = self.nodeId, let child = childContaining(centerOfMass) {
                child.insert(nodeId: existingId, position: centerOfMass)
            }
            self.nodeId = nil
        }

        // Insert into appropriate child
        if let child = childContaining(position) {
            child.insert(nodeId: nodeId, position: position)
        }
    }

    private func subdivide() {
        let midX = bounds.midX
        let midY = bounds.midY
        let halfWidth = bounds.width / 2
        let halfHeight = bounds.height / 2

        children = [
            QuadTreeNode(bounds: CGRect(x: bounds.minX, y: bounds.minY, width: halfWidth, height: halfHeight)), // NW
            QuadTreeNode(bounds: CGRect(x: midX, y: bounds.minY, width: halfWidth, height: halfHeight)), // NE
            QuadTreeNode(bounds: CGRect(x: bounds.minX, y: midY, width: halfWidth, height: halfHeight)), // SW
            QuadTreeNode(bounds: CGRect(x: midX, y: midY, width: halfWidth, height: halfHeight)) // SE
        ]
    }

    private func childContaining(_ point: CGPoint) -> QuadTreeNode? {
        guard let children = children else { return nil }
        let midX = bounds.midX
        let midY = bounds.midY

        if point.x < midX {
            return point.y < midY ? children[0] : children[2]
        } else {
            return point.y < midY ? children[1] : children[3]
        }
    }

    /// Calculate repulsion force on a node using Barnes-Hut approximation.
    /// theta is the threshold ratio (typically 0.5-1.0) - higher = faster but less accurate.
    func calculateForce(on targetId: Int64, at targetPos: CGPoint, theta: CGFloat, repulsionStrength: CGFloat) -> CGVector {
        guard totalMass > 0 else { return .zero }

        let dx = centerOfMass.x - targetPos.x
        let dy = centerOfMass.y - targetPos.y
        let distance = max(hypot(dx, dy), 1)

        // If this is a leaf with the same node, skip
        if nodeId == targetId {
            return .zero
        }

        // If this is a leaf or the node is far enough, treat as single mass
        let size = max(bounds.width, bounds.height)
        if children == nil || (size / distance) < theta {
            // Repulsion force: F = k * mass / d²
            let forceMagnitude = repulsionStrength * CGFloat(totalMass) / (distance * distance)
            return CGVector(
                dx: -(dx / distance) * forceMagnitude,
                dy: -(dy / distance) * forceMagnitude
            )
        }

        // Otherwise, recursively calculate from children
        var force = CGVector.zero
        if let children = children {
            for child in children {
                let childForce = child.calculateForce(on: targetId, at: targetPos, theta: theta, repulsionStrength: repulsionStrength)
                force.dx += childForce.dx
                force.dy += childForce.dy
            }
        }
        return force
    }
}

// MARK: - Force-Directed Layout

/// Force-directed graph layout algorithm using spring physics.
/// Uses Barnes-Hut approximation for O(n log n) performance on large graphs.
final class ForceDirectedLayout {

    // MARK: - State

    /// Current node positions indexed by node ID
    private(set) var positions: [Int64: CGPoint] = [:]

    /// Velocities for each node
    private var velocities: [Int64: CGVector] = [:]

    /// Nodes that are pinned (being dragged) - don't apply forces
    private var pinnedNodes: Set<Int64> = []

    /// Ordered list of node IDs for iteration
    private var nodeIds: [Int64] = []

    // MARK: - Physics Parameters

    /// Ideal distance between connected nodes
    var springLength: CGFloat = 120

    /// Strength of spring attraction (Hooke's law constant)
    var springStrength: CGFloat = 0.05

    /// Strength of node repulsion (Coulomb's law constant)
    var repulsionStrength: CGFloat = 8000

    /// Velocity damping factor per step
    var damping: CGFloat = 0.85

    /// Temperature decay (simulated annealing)
    var coolingFactor: CGFloat = 0.995

    /// Minimum movement threshold for stability detection
    var stabilityThreshold: CGFloat = 0.1

    /// Maximum velocity to prevent instability
    var maxVelocity: CGFloat = 50

    /// Barnes-Hut theta parameter (0.5-1.0, higher = faster but less accurate)
    var barnesHutTheta: CGFloat = 0.8

    // MARK: - Internal State

    /// Current simulation temperature (decreases over time)
    private var temperature: CGFloat = 1.0

    /// Whether the simulation has stabilized
    private(set) var isStable = false

    /// Total kinetic energy of the system
    private var totalKineticEnergy: CGFloat = 0

    /// Cached adjacency list for spring forces
    private var adjacency: [Int64: Set<Int64>] = [:]

    /// Frame counter for adaptive updates
    private var frameCount = 0

    // MARK: - Initialization

    /// Initialize layout with random positions for nodes.
    func initialize(nodes: [GraphNode], canvasSize: CGSize = CGSize(width: 1000, height: 800)) {
        positions.removeAll(keepingCapacity: true)
        velocities.removeAll(keepingCapacity: true)
        pinnedNodes.removeAll()
        adjacency.removeAll()
        isStable = false
        temperature = 1.0
        frameCount = 0

        let padding: CGFloat = 100
        let minX = padding
        let maxX = canvasSize.width - padding
        let minY = padding
        let maxY = canvasSize.height - padding

        nodeIds = nodes.map { $0.id }

        for node in nodes {
            let x = CGFloat.random(in: minX...maxX)
            let y = CGFloat.random(in: minY...maxY)
            positions[node.id] = CGPoint(x: x, y: y)
            velocities[node.id] = .zero
        }
    }

    /// Initialize layout with a specific node pinned at the canvas center and others arranged nearby.
    /// Used for focused/neighborhood views where one node should remain centered.
    func initializeWithCenter(
        nodes: [GraphNode],
        centeredNodeId: Int64,
        canvasSize: CGSize = CGSize(width: 1000, height: 800)
    ) {
        positions.removeAll(keepingCapacity: true)
        velocities.removeAll(keepingCapacity: true)
        pinnedNodes.removeAll()
        adjacency.removeAll()
        isStable = false
        temperature = 1.0
        frameCount = 0

        nodeIds = nodes.map { $0.id }

        let center = CGPoint(x: canvasSize.width / 2, y: canvasSize.height / 2)
        let radius = min(canvasSize.width, canvasSize.height) * 0.2
        let otherNodes = nodes.filter { $0.id != centeredNodeId }

        for node in nodes {
            if node.id == centeredNodeId {
                // Place the focused node at canvas center and pin it
                positions[node.id] = center
                pinnedNodes.insert(node.id)
            } else {
                // Arrange other nodes in a circle around the center
                let index = otherNodes.firstIndex(where: { $0.id == node.id }) ?? 0
                let angle = (2 * .pi * CGFloat(index)) / CGFloat(max(otherNodes.count, 1))
                let x = center.x + radius * cos(angle)
                let y = center.y + radius * sin(angle)
                positions[node.id] = CGPoint(x: x, y: y)
            }
            velocities[node.id] = .zero
        }
    }

    /// Initialize layout with existing positions.
    func initialize(nodePositions: [Int64: CGPoint]) {
        positions = nodePositions
        velocities.removeAll(keepingCapacity: true)
        pinnedNodes.removeAll()
        adjacency.removeAll()
        isStable = false
        temperature = 1.0
        frameCount = 0

        nodeIds = Array(nodePositions.keys)

        for nodeId in nodePositions.keys {
            velocities[nodeId] = .zero
        }
    }

    // MARK: - Simulation Step

    /// Run one iteration of the force simulation.
    /// Uses Barnes-Hut approximation for repulsion (O(n log n) instead of O(n²)).
    func step(edges: [GraphEdge]) {
        guard !isStable else { return }
        guard nodeIds.count > 1 else { return }

        frameCount += 1

        // Build adjacency list only when edges change (cache it)
        if adjacency.isEmpty {
            buildAdjacency(edges: edges)
        }

        // Build quadtree for Barnes-Hut approximation
        let quadTree = buildQuadTree()

        // Calculate forces for each node
        var forces: [Int64: CGVector] = [:]
        for nodeId in nodeIds {
            forces[nodeId] = .zero
        }

        // 1. Repulsion forces using Barnes-Hut approximation (O(n log n))
        for nodeId in nodeIds {
            guard let pos = positions[nodeId] else { continue }
            let force = quadTree.calculateForce(
                on: nodeId,
                at: pos,
                theta: barnesHutTheta,
                repulsionStrength: repulsionStrength
            )
            forces[nodeId]?.dx += force.dx
            forces[nodeId]?.dy += force.dy
        }

        // 2. Spring forces between connected nodes (Hooke's law)
        for nodeI in nodeIds {
            guard let posI = positions[nodeI] else { continue }
            guard let neighbors = adjacency[nodeI] else { continue }

            for nodeJ in neighbors {
                guard let posJ = positions[nodeJ] else { continue }

                let delta = CGVector(dx: posJ.x - posI.x, dy: posJ.y - posI.y)
                let distance = max(hypot(delta.dx, delta.dy), 1)

                // Spring force: F = k * (d - L)
                let displacement = distance - springLength
                let forceMagnitude = springStrength * displacement
                let forceX = (delta.dx / distance) * forceMagnitude
                let forceY = (delta.dy / distance) * forceMagnitude

                forces[nodeI]?.dx += forceX
                forces[nodeI]?.dy += forceY
            }
        }

        // 3. Apply forces to velocities and update positions
        totalKineticEnergy = 0

        for nodeId in nodeIds {
            // Skip pinned nodes
            guard !pinnedNodes.contains(nodeId) else { continue }

            guard var velocity = velocities[nodeId],
                  let force = forces[nodeId],
                  let position = positions[nodeId] else { continue }

            // Apply force with temperature scaling
            velocity.dx += force.dx * temperature
            velocity.dy += force.dy * temperature

            // Apply damping
            velocity.dx *= damping
            velocity.dy *= damping

            // Clamp velocity
            let speed = hypot(velocity.dx, velocity.dy)
            if speed > maxVelocity {
                let scale = maxVelocity / speed
                velocity.dx *= scale
                velocity.dy *= scale
            }

            // Update velocity
            velocities[nodeId] = velocity

            // Update position
            let newPosition = CGPoint(
                x: position.x + velocity.dx,
                y: position.y + velocity.dy
            )
            positions[nodeId] = newPosition

            // Accumulate kinetic energy
            totalKineticEnergy += velocity.dx * velocity.dx + velocity.dy * velocity.dy
        }

        // 4. Cool down temperature
        temperature *= coolingFactor

        // 5. Check for stability
        let averageEnergy = totalKineticEnergy / CGFloat(max(nodeIds.count, 1))
        if averageEnergy < stabilityThreshold && temperature < 0.01 {
            isStable = true
        }
    }

    // MARK: - Private Helpers

    private func buildAdjacency(edges: [GraphEdge]) {
        adjacency.removeAll(keepingCapacity: true)
        for edge in edges {
            for sourceId in edge.sourceNodeIds {
                for targetId in edge.targetNodeIds {
                    adjacency[sourceId, default: []].insert(targetId)
                    adjacency[targetId, default: []].insert(sourceId)
                }
            }
        }
    }

    private func buildQuadTree() -> QuadTreeNode {
        // Calculate bounds
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity

        for pos in positions.values {
            minX = min(minX, pos.x)
            maxX = max(maxX, pos.x)
            minY = min(minY, pos.y)
            maxY = max(maxY, pos.y)
        }

        // Add padding
        let padding: CGFloat = 100
        let bounds = CGRect(
            x: minX - padding,
            y: minY - padding,
            width: maxX - minX + padding * 2,
            height: maxY - minY + padding * 2
        )

        let quadTree = QuadTreeNode(bounds: bounds)

        for nodeId in nodeIds {
            if let pos = positions[nodeId] {
                quadTree.insert(nodeId: nodeId, position: pos)
            }
        }

        return quadTree
    }

    /// Invalidate adjacency cache (call when edges change).
    func invalidateAdjacency() {
        adjacency.removeAll()
    }

    // MARK: - Node Manipulation

    /// Pin a node at a specific position (for dragging).
    func pinNode(_ nodeId: Int64, at position: CGPoint) {
        pinnedNodes.insert(nodeId)
        positions[nodeId] = position
        velocities[nodeId] = .zero
    }

    /// Unpin a node and let physics resume.
    func unpinNode(_ nodeId: Int64) {
        pinnedNodes.remove(nodeId)
        velocities[nodeId] = .zero

        // Reset stability when user interaction occurs
        isStable = false
        temperature = max(temperature, 0.1)
    }

    /// Move a pinned node to a new position.
    func moveNode(_ nodeId: Int64, to position: CGPoint) {
        guard pinnedNodes.contains(nodeId) else { return }
        positions[nodeId] = position
    }

    /// Add new nodes to the layout, positioned in a circle around a reference point.
    ///
    /// Used when expanding a node's neighborhood in a focused view — the new
    /// nodes aren't yet known to the layout engine and need to be registered
    /// with initial positions and zero velocity. Adjacency is invalidated so
    /// spring forces pick up the new edges on the next step.
    func addNodes(_ newNodeIds: [Int64], near position: CGPoint, radius: CGFloat = 100) {
        let count = newNodeIds.count
        for (index, nodeId) in newNodeIds.enumerated() {
            guard positions[nodeId] == nil else { continue }
            let angle = (2 * .pi * CGFloat(index)) / CGFloat(max(count, 1))
            positions[nodeId] = CGPoint(
                x: position.x + radius * cos(angle),
                y: position.y + radius * sin(angle)
            )
            velocities[nodeId] = .zero
            self.nodeIds.append(nodeId)
        }
        adjacency.removeAll()
        isStable = false
        temperature = max(temperature, 0.5)
    }

    /// Reset the simulation to restart layout computation.
    func reset() {
        isStable = false
        temperature = 1.0
        frameCount = 0

        for nodeId in velocities.keys {
            velocities[nodeId] = .zero
        }
    }

    /// Get current position for a node.
    func position(for nodeId: Int64) -> CGPoint? {
        positions[nodeId]
    }

    /// Check if a node is currently pinned.
    func isPinned(_ nodeId: Int64) -> Bool {
        pinnedNodes.contains(nodeId)
    }

    // MARK: - Centering

    /// Apply an offset to all node positions.
    func applyOffset(dx: CGFloat, dy: CGFloat) {
        for nodeId in positions.keys {
            if let pos = positions[nodeId] {
                positions[nodeId] = CGPoint(x: pos.x + dx, y: pos.y + dy)
            }
        }
    }

    /// Center the graph in the given canvas size.
    func centerGraph(in canvasSize: CGSize) {
        guard !positions.isEmpty else { return }

        // Calculate bounding box
        var minX = CGFloat.infinity
        var maxX = -CGFloat.infinity
        var minY = CGFloat.infinity
        var maxY = -CGFloat.infinity

        for position in positions.values {
            minX = min(minX, position.x)
            maxX = max(maxX, position.x)
            minY = min(minY, position.y)
            maxY = max(maxY, position.y)
        }

        // Calculate center offset
        let graphCenterX = (minX + maxX) / 2
        let graphCenterY = (minY + maxY) / 2
        let canvasCenterX = canvasSize.width / 2
        let canvasCenterY = canvasSize.height / 2

        let offsetX = canvasCenterX - graphCenterX
        let offsetY = canvasCenterY - graphCenterY

        // Apply offset to all positions
        for nodeId in positions.keys {
            if let position = positions[nodeId] {
                positions[nodeId] = CGPoint(
                    x: position.x + offsetX,
                    y: position.y + offsetY
                )
            }
        }
    }
}
