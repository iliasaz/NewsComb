import Foundation

/// Represents an action entry from an OASIS JSONL action log.
///
/// OASIS logs actions as JSON Lines, one per line. Each entry records
/// what an agent did during a simulation round.
struct OasisAction: Codable, Sendable, Equatable {
    var agentId: Int?
    var agentName: String?
    var actionType: String?
    var round: Int?
    var content: String?
    var targetPostId: Int?
    var targetCommentId: Int?
    var groupId: Int?
    var groupName: String?
    var result: String?
    var success: Bool?
    var timestamp: Double?

    /// The OASIS post ID for actions that create a new post (quote_post, repost).
    /// Used during re-ingestion to set `oasisPostId` on the created SocialPost.
    var oasisNewPostId: Int?

    /// Event entries (round_start, round_end, simulation_end) use this field.
    var eventType: String?

    enum CodingKeys: String, CodingKey {
        case round, content, result, success, timestamp
        case agentId = "agent_id"
        case agentName = "agent_name"
        case actionType = "action_type"
        case targetPostId = "target_post_id"
        case targetCommentId = "target_comment_id"
        case groupId = "group_id"
        case groupName = "group_name"
        case eventType = "event_type"
    }

    /// Whether this entry represents a simulation lifecycle event rather than an agent action.
    var isEvent: Bool {
        eventType != nil
    }

    /// Whether this entry signals the end of the simulation.
    var isSimulationEnd: Bool {
        eventType == "simulation_end"
    }
}
