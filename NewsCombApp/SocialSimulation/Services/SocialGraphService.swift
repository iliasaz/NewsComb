import Foundation
import GRDB
import OSLog

/// Provides queries and enrichment operations for the social graph.
///
/// Reads from both the social graph tables and (read-only) the knowledge hypergraph
/// for context. Writes only to `social_*` and `agent_*` tables.
final class SocialGraphService: Sendable {

    private let database = Database.shared
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
