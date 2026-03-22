import SwiftUI

/// Displays a feed of posts from the simulation.
struct SimulationFeedView: View {
    let posts: [SocialPost]
    let agents: [SocialAgent]

    var body: some View {
        if posts.isEmpty {
            Text("No posts yet")
                .foregroundStyle(.secondary)
        } else {
            ForEach(posts) { post in
                PostRow(post: post, agent: agentForPost(post))
            }
        }
    }

    private func agentForPost(_ post: SocialPost) -> SocialAgent? {
        agents.first { $0.id == post.agentId }
    }
}

// MARK: - Post Row

private struct PostRow: View {
    let post: SocialPost
    let agent: SocialAgent?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                AgentAvatar(name: agent?.displayName ?? "?", size: 28)

                VStack(alignment: .leading) {
                    Text(agent?.displayName ?? "Unknown Agent")
                        .font(.subheadline)
                        .bold()
                    Text("Round \(post.roundNum)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(post.platform)
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary)
                    .clipShape(.capsule)
            }

            Text(post.content)
                .font(.body)

            if post.parentPostId != nil {
                Label("Reply", systemImage: "arrowshape.turn.up.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if post.repostOfId != nil {
                Label("Repost", systemImage: "arrow.2.squarepath")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Agent Avatar

struct AgentAvatar: View {
    let name: String
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(avatarColor)
                .frame(width: size, height: size)
            Text(initials)
                .font(.system(size: size * 0.4))
                .foregroundStyle(.white)
                .bold()
        }
    }

    private var initials: String {
        let parts = name.split(separator: " ")
        if parts.count >= 2 {
            return "\(parts[0].prefix(1))\(parts[1].prefix(1))"
        }
        return String(name.prefix(2)).uppercased()
    }

    private var avatarColor: Color {
        let hash = abs(name.hashValue)
        let colors: [Color] = [.blue, .purple, .teal, .orange, .pink, .indigo, .mint, .cyan]
        return colors[hash % colors.count]
    }
}
