import SwiftUI

/// Lists all groups created during a simulation with members and messages.
struct SimulationGroupsView: View {
    let simulationId: String

    @State private var groups: [SocialGraphService.GroupSummary] = []

    private let graphService = SocialGraphService()

    var body: some View {
        Group {
            if groups.isEmpty {
                Text("No groups created")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(groups) { group in
                    NavigationLink {
                        GroupDetailView(group: group)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(group.name)
                                .font(.headline)
                            HStack(spacing: 12) {
                                Label("\(group.memberCount)", systemImage: "person.2")
                                Label("\(group.messageCount)", systemImage: "text.bubble")
                                Text("Round \(group.roundNum)")
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            Text("Created by \(group.creatorName)")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }
        }
        .onAppear {
            do {
                groups = try graphService.groups(simulationId: simulationId)
            } catch {
                // Data will show as empty
            }
        }
    }
}
