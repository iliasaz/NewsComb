import SwiftUI

/// Displays a list of social agents in a simulation.
struct SimulationAgentListView: View {
    let agents: [SocialAgent]
    let simulationId: String

    var body: some View {
        if agents.isEmpty {
            Text("No agents generated yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(agents) { agent in
                NavigationLink(value: agent) {
                    AgentRow(agent: agent)
                }
            }
        }
    }
}

// MARK: - Agent Row

private struct AgentRow: View {
    let agent: SocialAgent

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(agent.displayName)
                    .font(.headline)
                Text(agent.bio)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        } icon: {
            AgentAvatar(name: agent.displayName, size: 32)
        }
    }
}
