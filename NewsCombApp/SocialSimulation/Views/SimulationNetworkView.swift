import SwiftUI

/// Interactive force-directed graph visualization of the social network.
///
/// Agents are nodes (sized by post count, colored by entity type).
/// Edges represent all interactions between agents, colored on a blue-to-red
/// heatmap scale reflecting interaction intensity.
/// Supports pinch-to-zoom, pan, and node dragging.
struct SimulationNetworkView: View {
    let simulationId: String

    @State private var agents: [SocialAgent] = []
    @State private var edges: [SocialGraphService.InteractionEdge] = []
    @State private var postCounts: [Int64: Int] = [:]
    @State private var positions: [Int64: CGPoint] = [:]
    @State private var isSimulating = false
    @State private var maxWeight: Int = 1

    // Viewport transformation
    @State private var scale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastScale: CGFloat = 1.0
    @State private var lastOffset: CGSize = .zero

    // Node dragging
    @State private var draggedNodeId: Int64?
    @State private var pinnedNodeIds: Set<Int64> = []

    // Edge detail popover
    @State private var selectedEdge: SocialGraphService.InteractionEdge?
    @State private var edgeDetails: [String: [SocialGraphService.InteractionDetail]] = [:]
    @State private var showEdgeDetail = false

    private let graphService = SocialGraphService()
    private let nodeRadius: CGFloat = 16

    // Layout parameters
    private let repulsion: CGFloat = 5000
    private let attraction: CGFloat = 0.01
    private let damping: CGFloat = 0.85
    private let idealLength: CGFloat = 120

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                Color(white: 0.12)
                    .ignoresSafeArea()

                Canvas { context, size in
                    // Apply viewport transformation
                    context.translateBy(x: offset.width + size.width / 2, y: offset.height + size.height / 2)
                    context.scaleBy(x: scale, y: scale)
                    context.translateBy(x: -size.width / 2, y: -size.height / 2)

                    drawEdges(context: context, size: size)
                    drawNodes(context: context, size: size)
                }
                .gesture(canvasGesture(in: geometry.size))
                .gesture(magnificationGesture)
                .onTapGesture { location in
                    let canvasCoord = screenToCanvas(location, in: geometry.size)
                    // Check nodes first (they're on top)
                    if hitTestNode(at: canvasCoord, in: geometry.size) != nil { return }
                    // Check edges
                    if let edge = hitTestEdge(at: canvasCoord, in: geometry.size) {
                        selectedEdge = edge
                        loadEdgeDetails(edge: edge)
                        showEdgeDetail = true
                    }
                }

                if agents.isEmpty {
                    ContentUnavailableView {
                        Label("No Network Data", systemImage: "network")
                    } description: {
                        Text("Generate agent profiles to see the social network.")
                    }
                }

                // Legend
                if !edges.isEmpty {
                    legendView
                }
            }
        }
        .navigationTitle("Social Network")
        .toolbar { toolbarContent }
        .sheet(isPresented: $showEdgeDetail) {
            edgeDetailSheet
        }
        .onAppear {
            loadData()
            startLayout()
        }
        .onDisappear {
            isSimulating = false
        }
    }

    // MARK: - Drawing

    private func drawEdges(context: GraphicsContext, size: CGSize) {
        for edge in edges {
            guard let from = positions[edge.fromId],
                  let to = positions[edge.toId] else { continue }

            let fromPoint = canvasPoint(from, in: size)
            let toPoint = canvasPoint(to, in: size)

            var path = Path()
            path.move(to: fromPoint)
            path.addLine(to: toPoint)

            let intensity = Double(edge.weight) / Double(maxWeight)
            let color = heatmapColor(intensity: intensity)
            let lineWidth = max(1, min(4, 1 + CGFloat(intensity) * 3))

            context.stroke(path, with: .color(color), lineWidth: lineWidth)

            // Arrow head
            let angle = atan2(toPoint.y - fromPoint.y, toPoint.x - fromPoint.x)
            let arrowLen: CGFloat = 6 + lineWidth
            let nodeR = nodeRadius
            let arrowPoint = CGPoint(
                x: toPoint.x - nodeR * cos(angle),
                y: toPoint.y - nodeR * sin(angle)
            )
            var arrow = Path()
            arrow.move(to: arrowPoint)
            arrow.addLine(to: CGPoint(
                x: arrowPoint.x - arrowLen * cos(angle - .pi / 6),
                y: arrowPoint.y - arrowLen * sin(angle - .pi / 6)
            ))
            arrow.move(to: arrowPoint)
            arrow.addLine(to: CGPoint(
                x: arrowPoint.x - arrowLen * cos(angle + .pi / 6),
                y: arrowPoint.y - arrowLen * sin(angle + .pi / 6)
            ))
            context.stroke(arrow, with: .color(color), lineWidth: max(1.5, lineWidth * 0.8))
        }
    }

    private func drawNodes(context: GraphicsContext, size: CGSize) {
        for agent in agents {
            guard let agentId = agent.id,
                  let pos = positions[agentId] else { continue }

            let point = canvasPoint(pos, in: size)
            let count = postCounts[agentId] ?? 0
            let radius = max(8, min(24, CGFloat(6 + count * 2)))

            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )

            let isDragged = draggedNodeId == agentId
            let isPinned = pinnedNodeIds.contains(agentId)
            let color: Color = isDragged ? .orange : avatarColor(for: agent.displayName)
            let strokeColor: Color = isPinned ? .orange : .white.opacity(0.5)

            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(strokeColor), lineWidth: isDragged || isPinned ? 2 : 1)

            // Label
            let text = Text(agent.displayName)
                .font(.system(size: 9))
                .foregroundStyle(.white)
            context.draw(
                context.resolve(text),
                at: CGPoint(x: point.x, y: point.y + radius + 8)
            )
        }
    }

    // MARK: - Gestures

    private func canvasGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                if draggedNodeId == nil {
                    let canvasPoint = screenToCanvas(value.startLocation, in: size)
                    if let nodeId = hitTestNode(at: canvasPoint, in: size) {
                        draggedNodeId = nodeId
                        pinnedNodeIds.insert(nodeId)
                    }
                }

                if let nodeId = draggedNodeId {
                    let canvasPoint = screenToCanvas(value.location, in: size)
                    positions[nodeId] = CGPoint(
                        x: canvasPoint.x - size.width / 2,
                        y: canvasPoint.y - size.height / 2
                    )
                } else {
                    offset = CGSize(
                        width: lastOffset.width + value.translation.width,
                        height: lastOffset.height + value.translation.height
                    )
                }
            }
            .onEnded { _ in
                if let nodeId = draggedNodeId {
                    pinnedNodeIds.remove(nodeId)
                    draggedNodeId = nil
                }
                lastOffset = offset
            }
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let newScale = lastScale * value
                scale = min(max(newScale, 0.1), 5.0)
            }
            .onEnded { _ in
                lastScale = scale
            }
    }

    // MARK: - Hit Testing & Coordinate Transforms

    private func screenToCanvas(_ screenPoint: CGPoint, in size: CGSize) -> CGPoint {
        let centeredX = screenPoint.x - size.width / 2 - offset.width
        let centeredY = screenPoint.y - size.height / 2 - offset.height
        let scaledX = centeredX / scale + size.width / 2
        let scaledY = centeredY / scale + size.height / 2
        return CGPoint(x: scaledX, y: scaledY)
    }

    private func hitTestNode(at canvasCoord: CGPoint, in size: CGSize) -> Int64? {
        for agent in agents.reversed() {
            guard let agentId = agent.id,
                  let pos = positions[agentId] else { continue }
            let count = postCounts[agentId] ?? 0
            let radius = max(8, min(24, CGFloat(6 + count * 2)))
            // Node is drawn at pos + size/2 in canvas space
            let nodeX = pos.x + size.width / 2
            let nodeY = pos.y + size.height / 2
            let distance = hypot(canvasCoord.x - nodeX, canvasCoord.y - nodeY)
            if distance <= radius {
                return agentId
            }
        }
        return nil
    }

    private func hitTestEdge(at canvasCoord: CGPoint, in size: CGSize) -> SocialGraphService.InteractionEdge? {
        let threshold: CGFloat = 8.0
        for edge in edges {
            guard let fromPos = positions[edge.fromId],
                  let toPos = positions[edge.toId] else { continue }
            let fromPt = CGPoint(x: fromPos.x + size.width / 2, y: fromPos.y + size.height / 2)
            let toPt = CGPoint(x: toPos.x + size.width / 2, y: toPos.y + size.height / 2)
            let distance = pointToLineDistance(point: canvasCoord, lineStart: fromPt, lineEnd: toPt)
            if distance <= threshold {
                return edge
            }
        }
        return nil
    }

    private func pointToLineDistance(point: CGPoint, lineStart: CGPoint, lineEnd: CGPoint) -> CGFloat {
        let dx = lineEnd.x - lineStart.x
        let dy = lineEnd.y - lineStart.y
        let lengthSq = dx * dx + dy * dy
        guard lengthSq > 0 else {
            return hypot(point.x - lineStart.x, point.y - lineStart.y)
        }
        let t = max(0, min(1, ((point.x - lineStart.x) * dx + (point.y - lineStart.y) * dy) / lengthSq))
        let projX = lineStart.x + t * dx
        let projY = lineStart.y + t * dy
        return hypot(point.x - projX, point.y - projY)
    }

    private func loadEdgeDetails(edge: SocialGraphService.InteractionEdge) {
        do {
            edgeDetails = try graphService.pairwiseInteractions(
                fromId: edge.fromId,
                toId: edge.toId,
                simulationId: simulationId
            )
        } catch {
            edgeDetails = [:]
        }
    }

    /// Canvas-local position for a node (node positions are stored as offsets from center).
    private func canvasPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }

    // MARK: - Colors

    private func heatmapColor(intensity: Double) -> Color {
        let t = min(max(intensity, 0), 1)
        if t < 0.5 {
            let s = t * 2
            return Color(red: s * 0.6, green: 0.1 * (1 - s), blue: 1.0 - s * 0.3)
        } else {
            let s = (t - 0.5) * 2
            return Color(red: 0.6 + s * 0.4, green: 0.0, blue: 0.7 * (1 - s))
        }
    }

    private func avatarColor(for name: String) -> Color {
        let hash = abs(name.hashValue)
        let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan]
        return colors[hash % colors.count]
    }

    // MARK: - Edge Detail Sheet

    private var edgeDetailSheet: some View {
        NavigationStack {
            Group {
                if let edge = selectedEdge {
                    let fromAgent = agents.first { $0.id == edge.fromId }
                    let toAgent = agents.first { $0.id == edge.toId }

                    ScrollView {
                        VStack(alignment: .leading, spacing: 16) {
                            // Header
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(fromAgent?.displayName ?? "Unknown")
                                        .font(.headline)
                                    Text("→ \(toAgent?.displayName ?? "Unknown")")
                                        .font(.headline)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text("\(edge.weight) interactions")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)

                            Divider()

                            if edgeDetails.isEmpty {
                                Text("No detailed interactions found")
                                    .foregroundStyle(.secondary)
                                    .padding()
                            } else {
                                ForEach(edgeDetails.keys.sorted(), id: \.self) { type in
                                    if let items = edgeDetails[type] {
                                        interactionSection(type: type, items: items)
                                    }
                                }
                            }
                        }
                        .padding(.vertical)
                    }
                } else {
                    Text("No edge selected")
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Interactions")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showEdgeDetail = false }
                }
            }
        }
        .frame(minWidth: 400, minHeight: 300)
    }

    private func interactionSection(type: String, items: [SocialGraphService.InteractionDetail]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(type.replacing("_", with: " ").capitalized)
                    .font(.subheadline)
                    .bold()
                    .foregroundStyle(sectionColor(for: type))
                Spacer()
                Text("\(items.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            ForEach(items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Text("Round \(item.roundNum)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 55, alignment: .trailing)

                    if let content = item.content, !content.isEmpty {
                        Text(content)
                            .font(.callout)
                            .lineLimit(3)
                    } else {
                        Text("(no content)")
                            .font(.callout)
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.horizontal)
            }

            Divider()
                .padding(.top, 4)
        }
    }

    private func sectionColor(for type: String) -> Color {
        switch type {
        case "like": .pink
        case "comment": .blue
        case "repost": .green
        case "follow": .orange
        case "shared group": .purple
        case "refresh": .gray
        default: .secondary
        }
    }

    // MARK: - Legend & Toolbar

    private var legendView: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Interaction Intensity")
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.7))
            HStack(spacing: 2) {
                Text("Low")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
                LinearGradient(
                    colors: [.blue, .purple, .red],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: 80, height: 6)
                .clipShape(.rect(cornerRadius: 3))
                Text("High")
                    .font(.caption2)
                    .foregroundStyle(.white.opacity(0.5))
            }
        }
        .padding(8)
        .background(.black.opacity(0.5))
        .clipShape(.rect(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding()
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem {
            HStack(spacing: 12) {
                Button("Zoom In", systemImage: "plus.magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = min(scale * 1.3, 5.0)
                        lastScale = scale
                    }
                }

                Button("Zoom Out", systemImage: "minus.magnifyingglass") {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        scale = max(scale / 1.3, 0.1)
                        lastScale = scale
                    }
                }

                Button("Reset View", systemImage: "arrow.counterclockwise") {
                    withAnimation(.easeInOut(duration: 0.3)) {
                        scale = 1.0
                        lastScale = 1.0
                        offset = .zero
                        lastOffset = .zero
                    }
                }
            }
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        do {
            agents = try graphService.agents(for: simulationId)
            edges = try graphService.interactionEdges(simulationId: simulationId)
            postCounts = try graphService.postCounts(simulationId: simulationId)
            maxWeight = max(1, edges.map(\.weight).max() ?? 1)
        } catch {
            // Data will show as empty
        }

        for agent in agents {
            guard let id = agent.id else { continue }
            positions[id] = CGPoint(
                x: CGFloat.random(in: -200...200),
                y: CGFloat.random(in: -200...200)
            )
        }
    }

    // MARK: - Force-Directed Layout

    private func startLayout() {
        guard !agents.isEmpty else { return }
        isSimulating = true

        Task {
            var velocities: [Int64: CGPoint] = [:]
            for agent in agents {
                if let id = agent.id {
                    velocities[id] = .zero
                }
            }

            for _ in 0..<200 {
                guard isSimulating else { break }

                var forces: [Int64: CGPoint] = [:]
                let agentIds = agents.compactMap(\.id)
                for id in agentIds { forces[id] = .zero }

                // Repulsion between all pairs
                for i in 0..<agentIds.count {
                    for j in (i + 1)..<agentIds.count {
                        let idA = agentIds[i]
                        let idB = agentIds[j]
                        guard let posA = positions[idA], let posB = positions[idB] else { continue }

                        let dx = posA.x - posB.x
                        let dy = posA.y - posB.y
                        let distSq = max(dx * dx + dy * dy, 1)
                        let force = repulsion / distSq
                        let dist = sqrt(distSq)

                        let fx = force * dx / dist
                        let fy = force * dy / dist

                        forces[idA]!.x += fx
                        forces[idA]!.y += fy
                        forces[idB]!.x -= fx
                        forces[idB]!.y -= fy
                    }
                }

                // Attraction along edges
                for edge in edges {
                    guard let posA = positions[edge.fromId],
                          let posB = positions[edge.toId] else { continue }

                    let dx = posB.x - posA.x
                    let dy = posB.y - posA.y
                    let dist = sqrt(dx * dx + dy * dy)
                    let weightFactor = 1.0 + CGFloat(edge.weight) / CGFloat(maxWeight)
                    let force = attraction * weightFactor * max(dist - idealLength, 0)

                    let fx = force * dx / max(dist, 1)
                    let fy = force * dy / max(dist, 1)

                    forces[edge.fromId]?.x += fx
                    forces[edge.fromId]?.y += fy
                    forces[edge.toId]?.x -= fx
                    forces[edge.toId]?.y -= fy
                }

                // Apply forces (skip pinned nodes)
                for id in agentIds {
                    guard !pinnedNodeIds.contains(id) else { continue }
                    guard let force = forces[id] else { continue }
                    var vel = velocities[id] ?? .zero
                    vel.x = (vel.x + force.x) * damping
                    vel.y = (vel.y + force.y) * damping
                    velocities[id] = vel

                    positions[id]?.x += vel.x
                    positions[id]?.y += vel.y
                }

                try? await Task.sleep(for: .milliseconds(16))
            }

            isSimulating = false
        }
    }
}
