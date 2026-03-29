import SwiftUI

/// Detail view for a single social group — members and messages.
struct GroupDetailView: View {
    let group: SocialGraphService.GroupSummary

    @State private var members: [SocialAgent] = []
    @State private var messages: [(agent: SocialAgent, content: String, roundNum: Int)] = []

    private let graphService = SocialGraphService()

    var body: some View {
        List {
            membersSection
            messagesSection
        }
        .navigationTitle(group.name)
        .onAppear { loadData() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var membersSection: some View {
        Section {
            if members.isEmpty {
                Text("No members")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(members) { agent in
                    NavigationLink {
                        AgentDetailView(agent: agent)
                    } label: {
                        HStack(spacing: 8) {
                            AgentAvatar(name: agent.displayName, size: 28)
                            Text(agent.displayName)
                        }
                    }
                }
            }
        } header: {
            Text("Members (\(members.count))")
        }
    }

    @ViewBuilder
    private var messagesSection: some View {
        Section {
            if messages.isEmpty {
                Text("No messages")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(messages.indices, id: \.self) { index in
                    let message = messages[index]
                    VStack(alignment: .leading, spacing: 4) {
                        HStack(spacing: 6) {
                            AgentAvatar(name: message.agent.displayName, size: 20)
                            Text(message.agent.displayName)
                                .font(.subheadline)
                                .bold()
                            Spacer()
                            Text("Round \(message.roundNum)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(message.content)
                            .font(.body)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Messages (\(messages.count))")
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        do {
            members = try graphService.groupMembers(groupId: group.id)
            messages = try graphService.groupMessages(groupId: group.id)
        } catch {
            // Data will show as empty
        }
    }
}
