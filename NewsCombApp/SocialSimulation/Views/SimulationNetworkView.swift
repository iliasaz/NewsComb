import SwiftUI

/// Force-directed graph visualization of the social network.
///
/// Agents are nodes (sized by post count, colored by entity type).
/// Social connections are directed edges.
struct SimulationNetworkView: View {
    let simulationId: String

    @State private var agents: [SocialAgent] = []
    @State private var edges: [SocialGraphService.NetworkEdge] = []
    @State private var postCounts: [Int64: Int] = [:]
    @State private var positions: [Int64: CGPoint] = [:]
    @State private var isSimulating = false

    private let graphService = SocialGraphService()

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
                    drawEdges(context: context, size: size)
                    drawNodes(context: context, size: size)
                }

                if agents.isEmpty {
                    ContentUnavailableView {
                        Label("No Network Data", systemImage: "network")
                    } description: {
                        Text("Generate agent profiles to see the social network.")
                    }
                }
            }
        }
        .navigationTitle("Social Network")
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

            let color: Color = edge.source == "initial" ? .gray.opacity(0.3) : .teal.opacity(0.5)
            context.stroke(path, with: .color(color), lineWidth: 1)

            // Arrow head
            let angle = atan2(toPoint.y - fromPoint.y, toPoint.x - fromPoint.x)
            let arrowLen: CGFloat = 8
            let arrowPoint = CGPoint(
                x: toPoint.x - 15 * cos(angle),
                y: toPoint.y - 15 * sin(angle)
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
            context.stroke(arrow, with: .color(color), lineWidth: 1.5)
        }
    }

    private func drawNodes(context: GraphicsContext, size: CGSize) {
        for agent in agents {
            guard let agentId = agent.id,
                  let pos = positions[agentId] else { continue }

            let point = canvasPoint(pos, in: size)
            let count = postCounts[agentId] ?? 0
            let radius = max(8, min(24, CGFloat(6 + count * 2)))

            // Node circle
            let rect = CGRect(
                x: point.x - radius,
                y: point.y - radius,
                width: radius * 2,
                height: radius * 2
            )
            let color = avatarColor(for: agent.displayName)
            context.fill(Path(ellipseIn: rect), with: .color(color))
            context.stroke(Path(ellipseIn: rect), with: .color(.white.opacity(0.5)), lineWidth: 1)

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

    private func canvasPoint(_ point: CGPoint, in size: CGSize) -> CGPoint {
        CGPoint(x: point.x + size.width / 2, y: point.y + size.height / 2)
    }

    private func avatarColor(for name: String) -> Color {
        let hash = abs(name.hashValue)
        let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan]
        return colors[hash % colors.count]
    }

    // MARK: - Data Loading

    private func loadData() {
        do {
            agents = try graphService.agents(for: simulationId)
            edges = try graphService.networkEdges(simulationId: simulationId)
            postCounts = try graphService.postCounts(simulationId: simulationId)
        } catch {
            // Data will show as empty
        }

        // Initialize random positions
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

                // Calculate forces
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
                    let force = attraction * max(dist - idealLength, 0)

                    let fx = force * dx / max(dist, 1)
                    let fy = force * dy / max(dist, 1)

                    forces[edge.fromId]?.x += fx
                    forces[edge.fromId]?.y += fy
                    forces[edge.toId]?.x -= fx
                    forces[edge.toId]?.y -= fy
                }

                // Apply forces
                for id in agentIds {
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
