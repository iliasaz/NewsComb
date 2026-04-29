import Foundation
import GRDB
import OSLog

/// Provides queries and enrichment operations for the social graph.
///
/// Reads from both the social graph tables and (read-only) the knowledge hypergraph
/// for context. Writes only to `social_*` and `agent_*` tables.
final class SocialGraphService: Sendable {

    private let database = Database.current
    private let logger = Logger(subsystem: "com.newscomb", category: "SocialGraphService")

    // MARK: - Agent Queries

    /// Fetches all agents for a simulation.
    func agents(for simulationId: String) throws -> [SocialAgent] {
        try database.read { db in
            try SocialAgent
                .filter(SocialAgent.Columns.simulationId == simulationId)
                .order(SocialAgent.Columns.displayName)
                .fetchAll(db)
        }
    }

    /// Fetches a single agent by ID.
    func agent(id: Int64) throws -> SocialAgent? {
        try database.read { db in
            try SocialAgent.fetchOne(db, id: id)
        }
    }

    // MARK: - Connection Queries

    /// Returns agents that the given agent follows.
    func following(agentId: Int64, simulationId: String) throws -> [SocialAgent] {
        try database.read { db in
            let sql = """
                SELECT a.*
                FROM social_agent a
                JOIN social_connection c ON c.followee_id = a.id
                WHERE c.follower_id = ? AND c.simulation_id = ?
                ORDER BY a.display_name
                """
            return try SocialAgent.fetchAll(db, sql: sql, arguments: [agentId, simulationId])
        }
    }

    /// Returns agents that follow the given agent.
    func followers(agentId: Int64, simulationId: String) throws -> [SocialAgent] {
        try database.read { db in
            let sql = """
                SELECT a.*
                FROM social_agent a
                JOIN social_connection c ON c.follower_id = a.id
                WHERE c.followee_id = ? AND c.simulation_id = ?
                ORDER BY a.display_name
                """
            return try SocialAgent.fetchAll(db, sql: sql, arguments: [agentId, simulationId])
        }
    }

    /// Returns the number of connections for each agent in a simulation.
    func connectionCounts(simulationId: String) throws -> [Int64: (following: Int, followers: Int)] {
        try database.read { db in
            let sql = """
                SELECT
                    a.id,
                    COALESCE(following.cnt, 0) AS following_count,
                    COALESCE(followers.cnt, 0) AS followers_count
                FROM social_agent a
                LEFT JOIN (
                    SELECT follower_id, COUNT(*) AS cnt
                    FROM social_connection WHERE simulation_id = ?
                    GROUP BY follower_id
                ) following ON following.follower_id = a.id
                LEFT JOIN (
                    SELECT followee_id, COUNT(*) AS cnt
                    FROM social_connection WHERE simulation_id = ?
                    GROUP BY followee_id
                ) followers ON followers.followee_id = a.id
                WHERE a.simulation_id = ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [simulationId, simulationId, simulationId])

            var result: [Int64: (following: Int, followers: Int)] = [:]
            for row in rows {
                let id: Int64 = row["id"]
                let following: Int = row["following_count"]
                let followers: Int = row["followers_count"]
                result[id] = (following: following, followers: followers)
            }
            return result
        }
    }

    // MARK: - Post Queries

    /// Fetches posts for a simulation, newest first.
    func posts(simulationId: String, limit: Int = 50, offset: Int = 0) throws -> [SocialPost] {
        try database.read { db in
            try SocialPost
                .filter(SocialPost.Columns.simulationId == simulationId)
                .order(SocialPost.Columns.simTimestamp.desc)
                .limit(limit, offset: offset)
                .fetchAll(db)
        }
    }

    /// Fetches posts by a specific agent.
    func posts(byAgentId agentId: Int64) throws -> [SocialPost] {
        try database.read { db in
            try SocialPost
                .filter(SocialPost.Columns.agentId == agentId)
                .order(SocialPost.Columns.simTimestamp.desc)
                .fetchAll(db)
        }
    }

    /// Returns post count per agent for a simulation.
    func postCounts(simulationId: String) throws -> [Int64: Int] {
        try database.read { db in
            let sql = """
                SELECT agent_id, COUNT(*) AS post_count
                FROM social_post
                WHERE simulation_id = ?
                GROUP BY agent_id
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [simulationId])
            var result: [Int64: Int] = [:]
            for row in rows {
                result[row["agent_id"]] = row["post_count"]
            }
            return result
        }
    }

    // MARK: - Interaction Queries

    /// Returns interaction count per action type for a simulation.
    func interactionSummary(simulationId: String) throws -> [String: Int] {
        try database.read { db in
            let sql = """
                SELECT action_type, COUNT(*) AS cnt
                FROM social_interaction
                WHERE simulation_id = ?
                GROUP BY action_type
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [simulationId])
            var result: [String: Int] = [:]
            for row in rows {
                let actionType: String = row["action_type"]
                result[actionType] = row["cnt"]
            }
            return result
        }
    }

    /// Returns interaction count per action type for a specific agent.
    func agentInteractionSummary(agentId: Int64, simulationId: String) throws -> [String: Int] {
        try database.read { db in
            let sql = """
                SELECT action_type, COUNT(*) AS cnt
                FROM social_interaction
                WHERE agent_id = ? AND simulation_id = ?
                GROUP BY action_type
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [agentId, simulationId])
            var result: [String: Int] = [:]
            for row in rows {
                let actionType: String = row["action_type"]
                result[actionType] = row["cnt"]
            }
            return result
        }
    }

    // MARK: - Simulation Stats

    struct SimulationStats: Sendable {
        let agentCount: Int
        let postCount: Int
        let interactionCount: Int
        let connectionCount: Int
        let latestRound: Int
    }

    /// Computes aggregate statistics for a simulation.
    func stats(simulationId: String) throws -> SimulationStats {
        try database.read { db in
            let agentCount = try SocialAgent
                .filter(SocialAgent.Columns.simulationId == simulationId)
                .fetchCount(db)
            let postCount = try SocialPost
                .filter(SocialPost.Columns.simulationId == simulationId)
                .fetchCount(db)
            let interactionCount = try SocialInteraction
                .filter(SocialInteraction.Columns.simulationId == simulationId)
                .fetchCount(db)
            let connectionCount = try SocialConnection
                .filter(SocialConnection.Columns.simulationId == simulationId)
                .fetchCount(db)

            let latestRound: Int = try Int.fetchOne(db, sql: """
                SELECT COALESCE(MAX(round_num), 0) FROM social_post WHERE simulation_id = ?
                """, arguments: [simulationId]) ?? 0

            return SimulationStats(
                agentCount: agentCount,
                postCount: postCount,
                interactionCount: interactionCount,
                connectionCount: connectionCount,
                latestRound: latestRound
            )
        }
    }

    // MARK: - Network Data (for visualization)

    struct NetworkEdge: Sendable {
        let fromId: Int64
        let toId: Int64
        let source: String
    }

    /// Returns all connections for force-directed graph visualization.
    func networkEdges(simulationId: String) throws -> [NetworkEdge] {
        try database.read { db in
            let sql = """
                SELECT follower_id, followee_id, source
                FROM social_connection
                WHERE simulation_id = ?
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [simulationId])
            return rows.map { row in
                NetworkEdge(
                    fromId: row["follower_id"],
                    toId: row["followee_id"],
                    source: row["source"]
                )
            }
        }
    }

    // MARK: - Group Queries

    /// A group with its member count and message count.
    struct GroupSummary: Identifiable, Sendable {
        let id: Int64
        let name: String
        let creatorName: String
        let memberCount: Int
        let messageCount: Int
        let roundNum: Int
    }

    /// Returns all groups for a simulation with summary counts.
    func groups(simulationId: String) throws -> [GroupSummary] {
        try database.read { db in
            let sql = """
                SELECT g.id, g.name, g.round_num,
                       a.display_name AS creator_name,
                       (SELECT COUNT(*) FROM social_group_member m WHERE m.group_id = g.id) AS member_count,
                       (SELECT COUNT(*) FROM social_group_message msg WHERE msg.group_id = g.id) AS message_count
                FROM social_group g
                JOIN social_agent a ON a.id = g.creator_agent_id
                WHERE g.simulation_id = ?
                ORDER BY member_count DESC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [simulationId])
            return rows.map { row in
                GroupSummary(
                    id: row["id"],
                    name: row["name"],
                    creatorName: row["creator_name"],
                    memberCount: row["member_count"],
                    messageCount: row["message_count"],
                    roundNum: row["round_num"]
                )
            }
        }
    }

    /// Returns agents who are members of a specific group.
    func groupMembers(groupId: Int64) throws -> [SocialAgent] {
        try database.read { db in
            let sql = """
                SELECT a.*
                FROM social_agent a
                JOIN social_group_member m ON m.agent_id = a.id
                WHERE m.group_id = ?
                ORDER BY a.display_name
                """
            return try SocialAgent.fetchAll(db, sql: sql, arguments: [groupId])
        }
    }

    /// Returns messages posted to a specific group.
    func groupMessages(groupId: Int64) throws -> [(agent: SocialAgent, content: String, roundNum: Int)] {
        try database.read { db in
            let sql = """
                SELECT msg.content, msg.round_num, a.*
                FROM social_group_message msg
                JOIN social_agent a ON a.id = msg.agent_id
                WHERE msg.group_id = ?
                ORDER BY msg.round_num DESC
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [groupId])
            return try rows.map { row in
                let agent = try SocialAgent(row: row)
                return (agent: agent, content: row["content"] as String, roundNum: row["round_num"] as Int)
            }
        }
    }

    // MARK: - Interaction Intensity (for network heatmap)

    /// Pairwise interaction weight between agents for network visualization.
    struct InteractionEdge: Sendable {
        let fromId: Int64
        let toId: Int64
        let weight: Int
    }

    /// Computes pairwise interaction intensity between all agents.
    ///
    /// Aggregates likes, comments, reposts, follows, and group co-membership
    /// into a single weight per directed pair.
    func interactionEdges(simulationId: String) throws -> [InteractionEdge] {
        try database.read { db in
            let sql = """
                SELECT from_id, to_id, SUM(weight) AS total_weight FROM (
                    -- Likes/interactions on another agent's post
                    SELECT i.agent_id AS from_id, p.agent_id AS to_id, COUNT(*) AS weight
                    FROM social_interaction i
                    JOIN social_post p ON p.id = i.post_id
                    WHERE i.simulation_id = ? AND i.agent_id != p.agent_id
                      AND i.action_type NOT IN ('refresh', 'trend', 'search_posts', 'do_nothing')
                    GROUP BY i.agent_id, p.agent_id

                    UNION ALL

                    -- Comments on another agent's post
                    SELECT c.agent_id AS from_id, p.agent_id AS to_id, COUNT(*) AS weight
                    FROM social_post c
                    JOIN social_post p ON p.id = c.parent_post_id
                    WHERE c.simulation_id = ? AND c.agent_id != p.agent_id
                    GROUP BY c.agent_id, p.agent_id

                    UNION ALL

                    -- Reposts of another agent's post
                    SELECT r.agent_id AS from_id, p.agent_id AS to_id, COUNT(*) AS weight
                    FROM social_post r
                    JOIN social_post p ON p.id = r.repost_of_id
                    WHERE r.simulation_id = ? AND r.agent_id != p.agent_id
                    GROUP BY r.agent_id, p.agent_id

                    UNION ALL

                    -- Follows
                    SELECT follower_id AS from_id, followee_id AS to_id, 2 AS weight
                    FROM social_connection
                    WHERE simulation_id = ?

                    UNION ALL

                    -- Group co-membership (bidirectional, weight 1 per shared group)
                    SELECT m1.agent_id AS from_id, m2.agent_id AS to_id, COUNT(*) AS weight
                    FROM social_group_member m1
                    JOIN social_group_member m2 ON m2.group_id = m1.group_id AND m2.agent_id != m1.agent_id
                    WHERE m1.simulation_id = ?
                    GROUP BY m1.agent_id, m2.agent_id
                )
                GROUP BY from_id, to_id
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [
                simulationId, simulationId, simulationId, simulationId, simulationId
            ])
            return rows.map { row in
                InteractionEdge(
                    fromId: row["from_id"],
                    toId: row["to_id"],
                    weight: row["total_weight"]
                )
            }
        }
    }

    /// A single interaction between two agents with its type and context.
    struct InteractionDetail: Identifiable, Sendable {
        let id: Int64
        let type: String
        let roundNum: Int
        let content: String?
    }

    /// Returns all individual interactions from one agent directed at another,
    /// grouped by type for display in the edge detail popover.
    ///
    /// Covers all the same sources as `interactionEdges()`:
    /// likes (with and without post_id), comments, reposts, follows, and group co-membership.
    func pairwiseInteractions(
        fromId: Int64,
        toId: Int64,
        simulationId: String
    ) throws -> [String: [InteractionDetail]] {
        try database.read { db in
            var results: [InteractionDetail] = []
            var nextId: Int64 = -1  // synthetic IDs for rows without a natural one

            // 1. Interactions with a resolved post_id (like on target's post)
            let resolvedSQL = """
                SELECT i.id, i.action_type, i.round_num, p.content
                FROM social_interaction i
                JOIN social_post p ON p.id = i.post_id
                WHERE i.agent_id = ? AND p.agent_id = ? AND i.simulation_id = ?
                ORDER BY i.round_num
                """
            for row in try Row.fetchAll(db, sql: resolvedSQL, arguments: [fromId, toId, simulationId]) {
                results.append(InteractionDetail(
                    id: row["id"], type: row["action_type"],
                    roundNum: row["round_num"], content: row["content"]
                ))
            }

            // 2. Interactions with NULL post_id (unresolved — common in pre-reingest data)
            //    Excludes non-social actions like refresh, trend, search_posts, do_nothing.
            //    Only include if there were no resolved interactions (avoids double-counting).
            if results.isEmpty {
                let unresolvedSQL = """
                    SELECT i.id, i.action_type, i.round_num
                    FROM social_interaction i
                    WHERE i.agent_id = ? AND i.post_id IS NULL AND i.simulation_id = ?
                      AND i.action_type NOT IN ('refresh', 'trend', 'search_posts', 'do_nothing',
                                                 'search_user', 'report_post', 'dislike_post',
                                                 'dislike_comment')
                    ORDER BY i.round_num
                    """
                for row in try Row.fetchAll(db, sql: unresolvedSQL, arguments: [fromId, simulationId]) {
                    results.append(InteractionDetail(
                        id: row["id"], type: row["action_type"],
                        roundNum: row["round_num"], content: nil
                    ))
                }
            }

            // 3. Comments on the target agent's posts
            let commentSQL = """
                SELECT c.id, c.round_num, c.content
                FROM social_post c
                JOIN social_post p ON p.id = c.parent_post_id
                WHERE c.agent_id = ? AND p.agent_id = ? AND c.simulation_id = ?
                ORDER BY c.round_num
                """
            for row in try Row.fetchAll(db, sql: commentSQL, arguments: [fromId, toId, simulationId]) {
                results.append(InteractionDetail(
                    id: row["id"], type: "comment",
                    roundNum: row["round_num"], content: row["content"]
                ))
            }

            // 4. Reposts of the target agent's posts
            let repostSQL = """
                SELECT r.id, r.round_num, r.content
                FROM social_post r
                JOIN social_post p ON p.id = r.repost_of_id
                WHERE r.agent_id = ? AND p.agent_id = ? AND r.simulation_id = ?
                ORDER BY r.round_num
                """
            for row in try Row.fetchAll(db, sql: repostSQL, arguments: [fromId, toId, simulationId]) {
                results.append(InteractionDetail(
                    id: row["id"], type: "repost",
                    roundNum: row["round_num"], content: row["content"]
                ))
            }

            // 5. Follows
            let followSQL = """
                SELECT id, round_num
                FROM social_connection
                WHERE follower_id = ? AND followee_id = ? AND simulation_id = ?
                """
            for row in try Row.fetchAll(db, sql: followSQL, arguments: [fromId, toId, simulationId]) {
                results.append(InteractionDetail(
                    id: row["id"], type: "follow",
                    roundNum: (row["round_num"] as Int?) ?? 0, content: nil
                ))
            }

            // 6. Group co-membership
            let groupSQL = """
                SELECT g.id, g.name, g.round_num
                FROM social_group g
                JOIN social_group_member m1 ON m1.group_id = g.id AND m1.agent_id = ?
                JOIN social_group_member m2 ON m2.group_id = g.id AND m2.agent_id = ?
                WHERE g.simulation_id = ?
                """
            for row in try Row.fetchAll(db, sql: groupSQL, arguments: [fromId, toId, simulationId]) {
                nextId -= 1
                results.append(InteractionDetail(
                    id: nextId, type: "shared group",
                    roundNum: row["round_num"], content: row["name"]
                ))
            }

            return Dictionary(grouping: results, by: \.type)
        }
    }

    // MARK: - Hypergraph Context (Read-Only)

    /// Assembles knowledge graph context for an agent's source node.
    /// Used for interviews and report generation.
    func knowledgeContext(for agent: SocialAgent) throws -> String {
        try database.read { db in
            // Get S-V-O triples involving the agent's source node
            let sql = """
                SELECT e.label AS edge_label,
                       src.label AS source_label,
                       tgt.label AS target_label,
                       p.chunk_text
                FROM hypergraph_incidence i
                JOIN hypergraph_edge e ON e.id = i.edge_id
                LEFT JOIN hypergraph_incidence si ON si.edge_id = e.id AND si.role = 'source'
                LEFT JOIN hypergraph_node src ON src.id = si.node_id
                LEFT JOIN hypergraph_incidence ti ON ti.edge_id = e.id AND ti.role = 'target'
                LEFT JOIN hypergraph_node tgt ON tgt.id = ti.node_id
                LEFT JOIN article_edge_provenance p ON p.edge_id = e.id
                WHERE i.node_id = ?
                ORDER BY e.id DESC
                LIMIT 20
                """
            let rows = try Row.fetchAll(db, sql: sql, arguments: [agent.nodeId])

            var parts: [String] = []

            // Format triples
            let triples = rows.compactMap { row -> String? in
                guard let source: String = row["source_label"],
                      let relation: String = row["edge_label"],
                      let target: String = row["target_label"] else { return nil }
                return "\(source) → \(relation) → \(target)"
            }
            if !triples.isEmpty {
                let uniqueTriples = Array(Set(triples)).prefix(15)
                parts.append("Known relationships:\n" + uniqueTriples.joined(separator: "\n"))
            }

            // Format provenance texts
            let provenanceTexts = rows.compactMap { row -> String? in
                guard let text: String = row["chunk_text"], !text.isEmpty else { return nil }
                return String(text.prefix(300))
            }
            let uniqueProvenance = Array(Set(provenanceTexts)).prefix(5)
            if !uniqueProvenance.isEmpty {
                parts.append("Source context:\n" + uniqueProvenance.map { "> \($0)" }.joined(separator: "\n\n"))
            }

            return parts.joined(separator: "\n\n")
        }
    }
}
