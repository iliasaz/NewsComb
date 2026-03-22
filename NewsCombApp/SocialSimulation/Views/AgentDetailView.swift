import SwiftUI

/// Detail view for a single social agent — shows persona, posts, and connections.
struct AgentDetailView: View {
    let agent: SocialAgent

    @State private var posts: [SocialPost] = []
    @State private var followingAgents: [SocialAgent] = []
    @State private var followerAgents: [SocialAgent] = []

    private let graphService = SocialGraphService()

    var body: some View {
        List {
            personaSection

            Section {
                NavigationLink {
                    AgentInterviewView(agent: agent)
                } label: {
                    Label("Interview Agent", systemImage: "bubble.left.and.bubble.right")
                }
            }

            postsSection
            connectionsSection
        }
        .navigationTitle(agent.displayName)
        .onAppear { loadData() }
    }

    // MARK: - Sections

    private var personaSection: some View {
        Section {
            HStack(spacing: 12) {
                AgentAvatar(name: agent.displayName, size: 48)
                VStack(alignment: .leading) {
                    Text(agent.displayName)
                        .font(.title3)
                        .bold()
                    Text(agent.bio)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let persona = agent.persona {
                if let profession = persona.profession {
                    LabeledContent("Profession", value: profession)
                }
                if !persona.interests.isEmpty {
                    LabeledContent("Interests") {
                        Text(persona.interests.joined(separator: ", "))
                            .foregroundStyle(.secondary)
                    }
                }
                if let mbti = persona.mbti {
                    LabeledContent("MBTI", value: mbti)
                }
                if let stance = persona.stance {
                    LabeledContent("Stance") {
                        Text(stance)
                            .foregroundStyle(.secondary)
                    }
                }

                HStack {
                    LabeledContent("Sentiment Bias") {
                        Text(persona.sentimentBias, format: .number.precision(.fractionLength(2)))
                            .foregroundStyle(persona.sentimentBias >= 0 ? .green : .red)
                    }
                    Spacer()
                    LabeledContent("Influence") {
                        Text(persona.influenceWeight, format: .number.precision(.fractionLength(2)))
                    }
                }
            }
        } header: {
            Text("Persona")
        }
    }

    @ViewBuilder
    private var postsSection: some View {
        Section {
            if posts.isEmpty {
                Text("No posts yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(posts.prefix(20)) { post in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(post.content)
                            .font(.body)
                        HStack {
                            Text("Round \(post.roundNum)")
                            Text(post.platform)
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                }
            }
        } header: {
            Text("Posts (\(posts.count))")
        }
    }

    @ViewBuilder
    private var connectionsSection: some View {
        Section {
            if followingAgents.isEmpty && followerAgents.isEmpty {
                Text("No connections")
                    .foregroundStyle(.secondary)
            } else {
                if !followingAgents.isEmpty {
                    DisclosureGroup("Following (\(followingAgents.count))") {
                        ForEach(followingAgents) { followee in
                            Label(followee.displayName, systemImage: "person.fill")
                                .font(.subheadline)
                        }
                    }
                }
                if !followerAgents.isEmpty {
                    DisclosureGroup("Followers (\(followerAgents.count))") {
                        ForEach(followerAgents) { follower in
                            Label(follower.displayName, systemImage: "person.fill")
                                .font(.subheadline)
                        }
                    }
                }
            }
        } header: {
            Text("Connections")
        }
    }

    // MARK: - Data Loading

    private func loadData() {
        guard let agentId = agent.id else { return }
        do {
            posts = try graphService.posts(byAgentId: agentId)
            followingAgents = try graphService.following(agentId: agentId, simulationId: agent.simulationId)
            followerAgents = try graphService.followers(agentId: agentId, simulationId: agent.simulationId)
        } catch {
            // Silently handle — data will show as empty
        }
    }
}
