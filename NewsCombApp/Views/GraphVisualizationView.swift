import SwiftUI
import HyperGraphReasoning

/// Interactive graph visualization view using Canvas.
struct GraphVisualizationView: View {

    @State private var viewModel = GraphViewModel()

    // Viewport transformation state
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    // Interaction state
    @State private var draggedNodeId: Int64?
    @State private var dragStartLocation: CGPoint = .zero

    // Color picker state
    @State private var nodeColor: Color = Color(hex: AppSettings.defaultGraphNodeColor) ?? .green

    // Node radius for hit testing
    private let nodeRadius: CGFloat = 20

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // Background
                Color(white: 0.12)
                    .ignoresSafeArea()

                // Main canvas
                graphCanvas(size: geometry.size)
                    .gesture(canvasGesture(in: geometry.size))
                    .gesture(magnificationGesture)
                    .onTapGesture(count: 2) { location in
                        let canvasPoint = screenToCanvas(location, in: geometry.size)
                        if let nodeId = hitTestNode(at: canvasPoint) {
                            viewModel.expandNode(nodeId)
                        }
                    }
                    .onContinuousHover { phase in
                        handleHover(phase: phase, in: geometry.size)
                    }

                // Node tooltip overlay
                if let nodeId = viewModel.hoveredNodeId,
                   let node = viewModel.node(id: nodeId) {
                    tooltipView(for: node, in: geometry.size)
                }

                // Edge tooltip overlay
                if let edgeId = viewModel.hoveredEdgeId,
                   let edge = viewModel.edge(id: edgeId) {
                    edgeTooltipView(for: edge, in: geometry.size)
                }

                // Loading overlay
                if viewModel.isLoading {
                    loadingOverlay
                }

                // Empty state
                if !viewModel.isLoading && viewModel.nodes.isEmpty {
                    emptyStateView
                }
            }
            .onAppear {
                viewModel.updateCanvasSize(geometry.size)
                viewModel.loadGraph()
                nodeColor = Color(hex: viewModel.nodeColorHex) ?? .green
            }
            .onChange(of: geometry.size) { _, newSize in
                viewModel.updateCanvasSize(newSize)
            }
        }
        .navigationTitle("Knowledge Graph")
        .toolbar {
            toolbarContent
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            if let error = viewModel.errorMessage {
                Text(error)
            }
        }
    }

    // MARK: - Canvas

    @ViewBuilder
    private func graphCanvas(size: CGSize) -> some View {
        Canvas { context, _ in
            // Apply viewport transformation
            context.translateBy(x: offset.width + size.width / 2, y: offset.height + size.height / 2)
            context.scaleBy(x: scale, y: scale)
            context.translateBy(x: -size.width / 2, y: -size.height / 2)

            // Calculate visible bounds in canvas coordinates for culling
            let visibleBounds = calculateVisibleBounds(canvasSize: size)

            // Draw edges first (underneath nodes) - with culling
            for edge in viewModel.visibleEdges {
                if isEdgeVisible(edge, in: visibleBounds) {
                    drawEdge(context: context, edge: edge)
                }
            }

            // Draw nodes on top - with culling
            for node in viewModel.visibleNodes {
                if isNodeVisible(node, in: visibleBounds) {
                    drawNode(context: context, node: node)
                }
            }
        }
        .drawingGroup() // Metal optimization
    }

    /// Calculate the visible bounds in canvas coordinates.
    private func calculateVisibleBounds(canvasSize: CGSize) -> CGRect {
        // Convert screen corners to canvas coordinates
        let topLeft = screenToCanvas(CGPoint.zero, in: canvasSize)
        let bottomRight = screenToCanvas(CGPoint(x: canvasSize.width, y: canvasSize.height), in: canvasSize)

        // Add padding for nodes at the edge
        let padding = nodeRadius * 2
        return CGRect(
            x: min(topLeft.x, bottomRight.x) - padding,
            y: min(topLeft.y, bottomRight.y) - padding,
            width: abs(bottomRight.x - topLeft.x) + padding * 2,
            height: abs(bottomRight.y - topLeft.y) + padding * 2
        )
    }

    /// Check if a node is within the visible bounds.
    private func isNodeVisible(_ node: GraphNode, in bounds: CGRect) -> Bool {
        bounds.contains(node.position)
    }

    /// Check if an edge has at least one endpoint visible.
    private func isEdgeVisible(_ edge: GraphEdge, in bounds: CGRect) -> Bool {
        // Check if any source or target node is visible
        for sourceId in edge.sourceNodeIds {
            if let node = viewModel.node(id: sourceId), bounds.contains(node.position) {
                return true
            }
        }
        for targetId in edge.targetNodeIds {
            if let node = viewModel.node(id: targetId), bounds.contains(node.position) {
                return true
            }
        }
        return false
    }

    // MARK: - Drawing

    private func drawNode(context: GraphicsContext, node: GraphNode) {
        let position = node.position
        let radius = nodeRadius

        // Node circle path
        let rect = CGRect(
            x: position.x - radius,
            y: position.y - radius,
            width: radius * 2,
            height: radius * 2
        )
        let path = Circle().path(in: rect)

        // Determine color based on state
        let isHovered = viewModel.hoveredNodeId == node.id
        let isDragged = draggedNodeId == node.id

        let fillColor: Color
        if isDragged {
            fillColor = .orange
        } else if isHovered {
            fillColor = .blue
        } else {
            fillColor = nodeTypeColor(node.nodeType)
        }

        // Draw filled circle with border
        context.fill(path, with: .color(fillColor.opacity(0.85)))
        context.stroke(
            path,
            with: .color(.white.opacity(0.9)),
            lineWidth: isDragged ? 3 : 2
        )

        // Draw label (truncated)
        let label = truncateLabel(node.label, maxWords: 2)
        var text = Text(label)
            .font(.caption2)
            .foregroundStyle(.white)

        if isHovered || isDragged {
            text = text.bold()
        }

        // Position label below node
        let labelPosition = CGPoint(x: position.x, y: position.y + radius + 10)
        context.draw(text, at: labelPosition, anchor: .top)
    }

    private func drawEdge(context: GraphicsContext, edge: GraphEdge) {
        let isSelected = viewModel.selectedEdgeId == edge.id
        let isHovered = viewModel.hoveredEdgeId == edge.id

        // Edge color based on hover/selection state
        let strokeColor: Color
        let lineWidth: CGFloat
        let opacity: Double

        if isHovered {
            strokeColor = .pink
            lineWidth = 3.0
            opacity = 1.0
        } else if isSelected {
            strokeColor = .red
            lineWidth = 2.5
            opacity = 1.0
        } else {
            strokeColor = .gray
            lineWidth = 1.0
            opacity = 0.5
        }

        // For hyperedges: draw lines from each source to each target
        for sourceId in edge.sourceNodeIds {
            for targetId in edge.targetNodeIds {
                guard let sourceNode = viewModel.node(id: sourceId),
                      let targetNode = viewModel.node(id: targetId) else { continue }

                let sourcePos = sourceNode.position
                let targetPos = targetNode.position

                // Create line path
                var path = Path()
                path.move(to: sourcePos)
                path.addLine(to: targetPos)

                // Draw the line
                context.stroke(
                    path,
                    with: .color(strokeColor.opacity(opacity)),
                    lineWidth: lineWidth
                )

                // Draw arrow head at target
                drawArrowHead(
                    context: context,
                    from: sourcePos,
                    to: targetPos,
                    color: strokeColor,
                    isHighlighted: isSelected || isHovered
                )
            }
        }
    }

    private func drawArrowHead(
        context: GraphicsContext,
        from source: CGPoint,
        to target: CGPoint,
        color: Color,
        isHighlighted: Bool
    ) {
        let arrowSize: CGFloat = isHighlighted ? 10 : 7

        // Calculate direction
        let dx = target.x - source.x
        let dy = target.y - source.y
        let length = hypot(dx, dy)
        guard length > 0 else { return }

        // Unit direction vector
        let unitX = dx / length
        let unitY = dy / length

        // Arrow tip is at target minus node radius
        let tipX = target.x - unitX * nodeRadius
        let tipY = target.y - unitY * nodeRadius

        // Perpendicular vector
        let perpX = -unitY
        let perpY = unitX

        // Arrow base points
        let baseX = tipX - unitX * arrowSize
        let baseY = tipY - unitY * arrowSize
        let left = CGPoint(x: baseX + perpX * arrowSize / 2, y: baseY + perpY * arrowSize / 2)
        let right = CGPoint(x: baseX - perpX * arrowSize / 2, y: baseY - perpY * arrowSize / 2)

        var arrowPath = Path()
        arrowPath.move(to: CGPoint(x: tipX, y: tipY))
        arrowPath.addLine(to: left)
        arrowPath.addLine(to: right)
        arrowPath.closeSubpath()

        context.fill(arrowPath, with: .color(color.opacity(isHighlighted ? 1.0 : 0.5)))
    }

    // MARK: - Helpers

    private func nodeTypeColor(_ nodeType: String?) -> Color {
        switch nodeType?.lowercased() {
        case "person":
            return .blue
        case "organization", "company":
            return .green
        case "location", "place":
            return .orange
        case "event":
            return .indigo
        case "concept":
            return .teal
        case "technology":
            return .cyan
        default:
            return nodeColor
        }
    }

    private func truncateLabel(_ label: String, maxWords: Int) -> String {
        let words = label.split(separator: " ")
        if words.count <= maxWords {
            return label
        }
        return words.prefix(maxWords).joined(separator: " ") + "..."
    }

    /// Formats a relation string to be human-readable.
    /// Converts "0_works_for" or "works_for" to "Works For".
    private func formatRelation(_ relation: String) -> String {
        // Remove leading numeric prefixes (like "0_" or "chunk_0_")
        var cleaned = relation

        // Remove patterns like "0_", "1_", "chunk_0_", etc. from the beginning
        let prefixPatterns = [#"^\d+_"#, #"^chunk_\d+_"#, #"^rel_\d+_"#]
        for pattern in prefixPatterns {
            if let regex = try? Regex(pattern) {
                cleaned = cleaned.replacing(regex, with: "")
            }
        }

        // Also remove trailing chunk references like "_chunk_0"
        if let suffixRegex = try? Regex(#"_chunk_\d+$"#) {
            cleaned = cleaned.replacing(suffixRegex, with: "")
        }

        // Replace underscores with spaces and capitalize words
        let words = cleaned.split(separator: "_")
        let formatted = words.map { word in
            word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }.joined(separator: " ")

        return formatted.isEmpty ? relation : formatted
    }

    // MARK: - Gestures

    private func canvasGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if draggedNodeId == nil {
                    // Check if we're starting on a node
                    let canvasPoint = screenToCanvas(value.startLocation, in: size)
                    if let nodeId = hitTestNode(at: canvasPoint) {
                        // Start dragging this node
                        draggedNodeId = nodeId
                        dragStartLocation = value.startLocation
                        viewModel.pinNode(nodeId)
                    }
                }

                if let nodeId = draggedNodeId {
                    // Move the dragged node
                    let canvasPoint = screenToCanvas(value.location, in: size)
                    viewModel.moveNode(nodeId, to: canvasPoint)
                } else {
                    // Pan the canvas
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                if let nodeId = draggedNodeId {
                    viewModel.unpinNode(nodeId)
                    draggedNodeId = nil
                }
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                // Clamp scale to reasonable bounds
                scale = min(max(newScale, 0.1), 5.0)
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    // MARK: - Hit Testing

    private func screenToCanvas(_ screenPoint: CGPoint, in size: CGSize) -> CGPoint {
        // Reverse the viewport transformation
        let centeredX = screenPoint.x - size.width / 2 - offset.width
        let centeredY = screenPoint.y - size.height / 2 - offset.height
        let scaledX = centeredX / scale + size.width / 2
        let scaledY = centeredY / scale + size.height / 2
        return CGPoint(x: scaledX, y: scaledY)
    }

    private func hitTestNode(at canvasPoint: CGPoint) -> Int64? {
        for node in viewModel.visibleNodes.reversed() {
            let dx = canvasPoint.x - node.position.x
            let dy = canvasPoint.y - node.position.y
            let distance = hypot(dx, dy)
            if distance <= nodeRadius {
                return node.id
            }
        }
        return nil
    }

    private func hitTestEdge(at canvasPoint: CGPoint, threshold: CGFloat = 5) -> Int64? {
        for edge in viewModel.visibleEdges {
            for sourceId in edge.sourceNodeIds {
                for targetId in edge.targetNodeIds {
                    guard let sourceNode = viewModel.node(id: sourceId),
                          let targetNode = viewModel.node(id: targetId) else { continue }

                    let distance = pointToLineDistance(
                        point: canvasPoint,
                        lineStart: sourceNode.position,
                        lineEnd: targetNode.position
                    )

                    if distance <= threshold {
                        return edge.id
                    }
                }
            }
        }
        return nil
    }

    private func pointToLineDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lineLengthSq = dx * dx + dy * dy

        guard lineLengthSq > 0 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }

        // Project point onto line
        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lineLengthSq))
        let projectionX = lineStart.x + t * dx
        let projectionY = lineStart.y + t * dy

        return hypot(point.x - projectionX, point.y - projectionY)
    }

    // MARK: - Hover Handling

    private func handleHover(phase: HoverPhase, in size: CGSize) {
        switch phase {
        case .active(let location):
            let canvasPoint = screenToCanvas(location, in: size)
            // First check nodes (they're on top)
            if let nodeId = hitTestNode(at: canvasPoint) {
                viewModel.hoveredNodeId = nodeId
                viewModel.hoveredEdgeId = nil
            } else if let edgeId = hitTestEdge(at: canvasPoint, threshold: 8) {
                // Then check edges
                viewModel.hoveredNodeId = nil
                viewModel.hoveredEdgeId = edgeId
            } else {
                viewModel.hoveredNodeId = nil
                viewModel.hoveredEdgeId = nil
            }
        case .ended:
            viewModel.hoveredNodeId = nil
            viewModel.hoveredEdgeId = nil
        }
    }

    // MARK: - Overlays

    @ViewBuilder
    private func tooltipView(for node: GraphNode, in size: CGSize) -> some View {
        let screenPos = canvasToScreen(node.position, in: size)

        VStack(alignment: .leading, spacing: 4) {
            Text(node.label)
                .font(.headline)
                .foregroundStyle(.primary)

            if let nodeType = node.nodeType {
                Text(nodeType)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text("Connections: \(node.degree)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .position(x: screenPos.x, y: screenPos.y - nodeRadius * scale - 50)
    }

    @ViewBuilder
    private func edgeTooltipView(for edge: GraphEdge, in size: CGSize) -> some View {
        // Calculate center point of the edge for tooltip positioning
        let centerPos = edgeCenterPosition(edge, in: size)

        VStack(alignment: .leading, spacing: 6) {
            // Relation/type of connection (extracted from edgeId)
            Text(formatRelation(ContextCollector.extractRelation(from: edge.edgeId) ?? edge.relation))
                .font(.headline)
                .foregroundStyle(.pink)

            // Source nodes
            if !edge.sourceNodeIds.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("From:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(edge.sourceNodeIds, id: \.self) { nodeId in
                        if let node = viewModel.node(id: nodeId) {
                            Text("• \(node.label)")
                                .font(.caption)
                        }
                    }
                }
            }

            // Target nodes
            if !edge.targetNodeIds.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("To:")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    ForEach(edge.targetNodeIds, id: \.self) { nodeId in
                        if let node = viewModel.node(id: nodeId) {
                            Text("• \(node.label)")
                                .font(.caption)
                        }
                    }
                }
            }
        }
        .padding(10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .position(x: centerPos.x, y: centerPos.y - 60)
    }

    private func edgeCenterPosition(_ edge: GraphEdge, in size: CGSize) -> CGPoint {
        // Calculate average position of all connected nodes
        var sumX: CGFloat = 0
        var sumY: CGFloat = 0
        var count: CGFloat = 0

        for nodeId in edge.sourceNodeIds + edge.targetNodeIds {
            if let node = viewModel.node(id: nodeId) {
                let screenPos = canvasToScreen(node.position, in: size)
                sumX += screenPos.x
                sumY += screenPos.y
                count += 1
            }
        }

        guard count > 0 else { return CGPoint(x: size.width / 2, y: size.height / 2) }
        return CGPoint(x: sumX / count, y: sumY / count)
    }

    private func canvasToScreen(_ canvasPoint: CGPoint, in size: CGSize) -> CGPoint {
        let centeredX = canvasPoint.x - size.width / 2
        let centeredY = canvasPoint.y - size.height / 2
        let scaledX = centeredX * scale + size.width / 2 + offset.width
        let scaledY = centeredY * scale + size.height / 2 + offset.height
        return CGPoint(x: scaledX, y: scaledY)
    }

    private var loadingOverlay: some View {
        VStack {
            ProgressView()
                .controlSize(.large)
            Text("Loading graph...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyStateView: some View {
        ContentUnavailableView(
            "No Knowledge Graph",
            systemImage: "brain.head.profile",
            description: Text("Process articles to build a knowledge graph.")
        )
    }

    // MARK: - Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            HStack(spacing: 12) {
                // Connection threshold stepper
                HStack(spacing: 2) {
                    Text("Min:")
                        .font(.caption)
                    TextField("", value: $viewModel.connectionThreshold, format: .number)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 50)
                        .multilineTextAlignment(.center)
                    Stepper("", value: $viewModel.connectionThreshold, in: 1...max(viewModel.maxDegree, 1))
                        .labelsHidden()
                }
                .help("Minimum connections to show node")

                // Color picker as small circle
                colorPickerCircle

                Divider()
                    .frame(height: 20)

                // Zoom controls
                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = min(scale * 1.3, 5.0)
                        lastScale = scale
                    }
                }
                .help("Zoom in")

                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = max(scale / 1.3, 0.1)
                        lastScale = scale
                    }
                }
                .help("Zoom out")

                Button("Reset View", systemImage: "arrow.counterclockwise") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
                .help("Reset zoom and pan")

                Button("Center", systemImage: "scope") {
                    viewModel.centerGraph()
                }
                .help("Center graph in view")

                Divider()
                    .frame(height: 20)

                // Simulation controls
                Button(
                    viewModel.isSimulating ? "Pause" : "Simulate",
                    systemImage: viewModel.isSimulating ? "pause.fill" : "play.fill"
                ) {
                    viewModel.toggleSimulation()
                }
                .help(viewModel.isSimulating ? "Pause layout simulation" : "Resume layout simulation")

                Button("Reload", systemImage: "arrow.clockwise") {
                    viewModel.reloadGraph()
                }
                .help("Reload graph data")

                Divider()
                    .frame(height: 20)

                // Stats button
                statsButton
            }
        }
    }

    @State private var showingColorPicker = false

    private var colorPickerCircle: some View {
        Circle()
            .fill(nodeColor)
            .stroke(Color.primary.opacity(0.3), lineWidth: 1)
            .frame(width: 20, height: 20)
            .popover(isPresented: $showingColorPicker) {
                ColorPicker("Node Color", selection: $nodeColor)
                    .padding()
                    .onChange(of: nodeColor) { _, newColor in
                        viewModel.saveNodeColor(newColor.hexString)
                    }
            }
            .onTapGesture {
                showingColorPicker.toggle()
            }
            .help("Default node color")
    }

    @State private var showingStats = false

    private var statsButton: some View {
        Button("Stats", systemImage: "chart.bar") {
            showingStats.toggle()
        }
        .popover(isPresented: $showingStats) {
            statsPopoverContent
        }
        .help("Graph statistics")
    }

    private var statsPopoverContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Graph Statistics")
                .font(.headline)

            Divider()

            // Nodes section
            VStack(alignment: .leading, spacing: 4) {
                Text("Nodes")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                StatRow(label: "Total", value: "\(viewModel.nodes.count)")
                StatRow(label: "Visible", value: "\(viewModel.visibleNodes.count)")
                StatRow(label: "Hidden", value: "\(viewModel.nodes.count - viewModel.visibleNodes.count)")
            }

            // Edges section
            VStack(alignment: .leading, spacing: 4) {
                Text("Edges")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                StatRow(label: "Total", value: "\(viewModel.edges.count)")
                StatRow(label: "Visible", value: "\(viewModel.visibleEdges.count)")
            }

            // Connectivity section
            VStack(alignment: .leading, spacing: 4) {
                Text("Connectivity")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                StatRow(label: "Max connections", value: "\(viewModel.maxDegree)")
                StatRow(label: "Avg connections", value: String(format: "%.1f", averageDegree))
                StatRow(label: "Isolated nodes", value: "\(isolatedNodeCount)")
                StatRow(label: "Density", value: String(format: "%.2f%%", graphDensity * 100))
            }

            // Top connected nodes
            if !topConnectedNodes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Most Connected")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    ForEach(topConnectedNodes, id: \.id) { node in
                        HStack {
                            Text(node.label)
                                .lineLimit(1)
                            Spacer()
                            Text("\(node.degree)")
                                .foregroundStyle(.secondary)
                        }
                        .font(.caption)
                    }
                }
            }
        }
        .padding()
        .frame(width: 220)
    }

    private var averageDegree: Double {
        guard !viewModel.nodes.isEmpty else { return 0 }
        let totalDegree = viewModel.nodes.reduce(0) { $0 + $1.degree }
        return Double(totalDegree) / Double(viewModel.nodes.count)
    }

    private var isolatedNodeCount: Int {
        viewModel.nodes.filter { $0.degree == 0 }.count
    }

    private var graphDensity: Double {
        // Density = actual edges / possible edges
        // For directed graph: possible = n * (n - 1)
        let n = viewModel.nodes.count
        guard n > 1 else { return 0 }
        let possibleEdges = n * (n - 1)
        return Double(viewModel.edges.count) / Double(possibleEdges)
    }

    private var topConnectedNodes: [GraphNode] {
        Array(viewModel.nodes.sorted { $0.degree > $1.degree }.prefix(5))
    }
}

private struct StatRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.caption)
    }
}

// MARK: - Color Extensions

extension Color {
    /// Initialize a Color from a hex string (6 characters, no #).
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacing("#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        Scanner(string: hexSanitized).scanHexInt64(&rgb)

        let r = Double((rgb >> 16) & 0xFF) / 255.0
        let g = Double((rgb >> 8) & 0xFF) / 255.0
        let b = Double(rgb & 0xFF) / 255.0

        self.init(red: r, green: g, blue: b)
    }

    /// Convert color to hex string.
    var hexString: String {
        #if canImport(AppKit)
        guard let components = NSColor(self).usingColorSpace(.deviceRGB)?.cgColor.components,
              components.count >= 3 else {
            return "808080"
        }
        let r = Int(components[0] * 255)
        let g = Int(components[1] * 255)
        let b = Int(components[2] * 255)
        return String(format: "%02X%02X%02X", r, g, b)
        #else
        return "808080"
        #endif
    }
}

#Preview {
    GraphVisualizationView()
}
