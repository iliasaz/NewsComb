import Foundation
import GRDB
import OSLog

/// Maps OASIS action log entries to NewsComb social graph records.
///
/// Stateless service that transforms `OasisAction` batches into `SocialPost`,
/// `SocialInteraction`, and `SocialConnection` records. Writes only to the
/// social graph tables, never to the knowledge hypergraph.
final class ActionIngestionService: Sendable {

    private let database = Database.current
    private let logger = Logger(subsystem: "com.newscomb", category: "ActionIngestion")

    // MARK: - Public API

    /// Ingests a batch of OASIS actions into the social graph.
    ///
    /// - Parameters:
    ///   - actions: Actions parsed from OASIS JSONL logs.
    ///   - simulationId: The simulation these actions belong to.
    ///   - agentMapping: Maps OASIS agent_id → NewsComb social_agent.id.
    /// - Returns: The number of records created.
    @discardableResult
    func ingest(
        actions: [OasisAction],
        simulationId: String,
        agentMapping: [Int: Int64]
    ) throws -> IngestResult {
        var result = IngestResult()

        // Filter out event entries (round_start, round_end, simulation_end)
        let agentActions = actions.filter { !$0.isEvent }

        guard !agentActions.isEmpty else { return result }

        try database.write { db in
            for action in agentActions {
                guard let oasisAgentId = action.agentId,
                      let agentId = agentMapping[oasisAgentId] else {
                    continue
                }

                let roundNum = action.round ?? 0
                let simTimestamp = action.timestamp ?? Double(roundNum) * 3600.0

                switch action.actionType {
                case "create_post", "CREATE_POST":
                    guard let content = action.content, !content.isEmpty else { continue }
                    let post = SocialPost(
                        agentId: agentId,
                        content: content,
                        simTimestamp: simTimestamp,
                        roundNum: roundNum,
                        platform: "twitter",
                        oasisPostId: action.targetPostId,
                        simulationId: simulationId
                    )
                    try post.insert(db)
                    result.postsCreated += 1

                case "create_comment", "CREATE_COMMENT":
                    guard let content = action.content else { continue }
                    let parentId = resolvePostId(oasisPostId: action.targetPostId, simulationId: simulationId, db: db)
                    // targetCommentId is the comment's own OASIS ID (from comment_id in trace)
                    let post = SocialPost(
                        agentId: agentId,
                        content: content,
                        parentPostId: parentId,
                        simTimestamp: simTimestamp,
                        roundNum: roundNum,
                        platform: "twitter",
                        oasisPostId: action.targetCommentId,
                        simulationId: simulationId
                    )
                    try post.insert(db)
                    result.postsCreated += 1

                case "repost", "REPOST", "quote_post", "QUOTE_POST":
                    let repostOfId = resolvePostId(oasisPostId: action.targetPostId, simulationId: simulationId, db: db)
                    let content = action.content ?? ""
                    // oasisNewPostId is the new post's OASIS ID (from new_post_id in trace)
                    let post = SocialPost(
                        agentId: agentId,
                        content: content,
                        repostOfId: repostOfId,
                        simTimestamp: simTimestamp,
                        roundNum: roundNum,
                        platform: "twitter",
                        oasisPostId: action.oasisNewPostId,
                        simulationId: simulationId
                    )
                    try post.insert(db)
                    result.postsCreated += 1

                case "like_post", "LIKE_POST", "like_comment", "LIKE_COMMENT":
                    let postId = resolvePostId(oasisPostId: action.targetPostId, simulationId: simulationId, db: db)
                    let interaction = SocialInteraction(
                        agentId: agentId,
                        postId: postId,
                        actionType: "like",
                        simTimestamp: simTimestamp,
                        roundNum: roundNum,
                        simulationId: simulationId
                    )
                    try interaction.insert(db)
                    result.interactionsCreated += 1

                case "follow", "FOLLOW":
                    guard let targetOasisId = action.targetPostId,
                          let targetAgentId = agentMapping[targetOasisId] else { continue }
                    // Insert with conflict ignore (UNIQUE constraint)
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO social_connection
                            (follower_id, followee_id, source, round_num, simulation_id)
                            VALUES (?, ?, 'simulation', ?, ?)
                            """,
                        arguments: [agentId, targetAgentId, roundNum, simulationId]
                    )
                    result.connectionsCreated += 1

                case "create_group", "CREATE_GROUP":
                    let groupName = action.groupName ?? action.content ?? "Unnamed Group"
                    try db.execute(
                        sql: """
                            INSERT OR IGNORE INTO social_group
                            (oasis_group_id, name, creator_agent_id, round_num, simulation_id)
                            VALUES (?, ?, ?, ?, ?)
                            """,
                        arguments: [action.groupId, groupName, agentId, roundNum, simulationId]
                    )
                    // Creator auto-joins the group
                    if let oasisGid = action.groupId {
                        let groupId = try resolveGroupId(oasisGroupId: oasisGid, simulationId: simulationId, db: db)
                        if let gid = groupId {
                            try db.execute(
                                sql: """
                                    INSERT OR IGNORE INTO social_group_member
                                    (group_id, agent_id, round_num, simulation_id)
                                    VALUES (?, ?, ?, ?)
                                    """,
                                arguments: [gid, agentId, roundNum, simulationId]
                            )
                        }
                    }
                    result.interactionsCreated += 1

                case "join_group", "JOIN_GROUP":
                    if let oasisGid = action.groupId,
                       let groupId = try resolveGroupId(oasisGroupId: oasisGid, simulationId: simulationId, db: db) {
                        try db.execute(
                            sql: """
                                INSERT OR IGNORE INTO social_group_member
                                (group_id, agent_id, round_num, simulation_id)
                                VALUES (?, ?, ?, ?)
                                """,
                            arguments: [groupId, agentId, roundNum, simulationId]
                        )
                    }
                    result.interactionsCreated += 1

                case "send_to_group", "SEND_TO_GROUP":
                    if let oasisGid = action.groupId,
                       let groupId = try resolveGroupId(oasisGroupId: oasisGid, simulationId: simulationId, db: db) {
                        let message = action.content ?? ""
                        try db.execute(
                            sql: """
                                INSERT INTO social_group_message
                                (group_id, agent_id, content, round_num, simulation_id)
                                VALUES (?, ?, ?, ?, ?)
                                """,
                            arguments: [groupId, agentId, message, roundNum, simulationId]
                        )
                    }
                    result.interactionsCreated += 1

                case "do_nothing", "DO_NOTHING":
                    break

                default:
                    // Unknown action type — record as interaction
                    if let actionType = action.actionType {
                        let interaction = SocialInteraction(
                            agentId: agentId,
                            actionType: actionType,
                            simTimestamp: simTimestamp,
                            roundNum: roundNum,
                            simulationId: simulationId
                        )
                        try interaction.insert(db)
                        result.interactionsCreated += 1
                    }
                }
            }
        }

        if result.totalCreated > 0 {
            logger.info("Ingested \(result.postsCreated) posts, \(result.interactionsCreated) interactions, \(result.connectionsCreated) connections")
        }

        return result
    }

    /// Extracts the latest round number from a batch of actions.
    func latestRound(in actions: [OasisAction]) -> Int? {
        actions.compactMap { action -> Int? in
            if action.eventType == "round_end" {
                return action.round
            }
            return nil
        }.max()
    }

    // MARK: - Helpers

    /// Attempts to resolve an OASIS post ID to a NewsComb SocialPost ID.
    /// Returns nil if not found (the referenced post may not have been ingested yet).
    private func resolvePostId(oasisPostId: Int?, simulationId: String, db: GRDB.Database) -> Int64? {
        guard let oasisId = oasisPostId else { return nil }
        return try? Int64.fetchOne(
            db,
            sql: "SELECT id FROM social_post WHERE oasis_post_id = ? AND simulation_id = ?",
            arguments: [oasisId, simulationId]
        )
    }

    /// Resolves an OASIS group ID to a NewsComb social_group ID.
    private func resolveGroupId(oasisGroupId: Int, simulationId: String, db: GRDB.Database) throws -> Int64? {
        try Int64.fetchOne(
            db,
            sql: "SELECT id FROM social_group WHERE oasis_group_id = ? AND simulation_id = ?",
            arguments: [oasisGroupId, simulationId]
        )
    }

    // MARK: - Re-ingestion from OASIS DB

    /// Re-ingests all actions for a simulation by reading directly from the OASIS trace table.
    ///
    /// Clears existing posts, interactions, connections, and groups for the simulation,
    /// then re-reads from the OASIS SQLite database.
    @discardableResult
    func reingestFromOasisDB(
        simulationId: String,
        oasisDBPath: String,
        agentMapping: [Int: Int64]
    ) throws -> IngestResult {
        // Read all traces from OASIS DB
        let oasisDB = try DatabaseQueue(path: oasisDBPath)
        let traces: [(agentId: Int, round: Int, action: String, info: String)] = try oasisDB.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT user_id, created_at, action, info FROM trace ORDER BY created_at")
            return rows.map { row in
                (agentId: row["user_id"] as Int,
                 round: row["created_at"] as Int,
                 action: row["action"] as String,
                 info: row["info"] as String)
            }
        }

        // Read comment → parent post mapping from OASIS DB
        let commentParents: [Int: Int] = (try? oasisDB.read { db -> [Int: Int] in
            let rows = try Row.fetchAll(db, sql: "SELECT comment_id, post_id FROM comment")
            var mapping: [Int: Int] = [:]
            for row in rows {
                mapping[row["comment_id"] as Int] = row["post_id"] as Int
            }
            return mapping
        }) ?? [:]

        // Convert to OasisActions, mapping OASIS-specific field names per action type.
        let actions: [OasisAction] = traces.compactMap { trace in
            guard let infoData = trace.info.data(using: .utf8),
                  let args = try? JSONSerialization.jsonObject(with: infoData) as? [String: Any] else {
                return nil
            }

            // OASIS uses different field names per action:
            //   create_post:    post_id (the created post)
            //   like_post:      post_id (the liked post)
            //   create_comment: comment_id (the created comment), parent from comment table
            //   quote_post:     quoted_id (original), new_post_id (the new post)
            //   repost:         reposted_id (original), new_post_id (the new post)
            //   follow:         followee_id (the followed user)
            let targetPostId: Int?
            let commentId: Int? = args["comment_id"] as? Int

            switch trace.action {
            case "create_post", "like_post", "like_comment":
                targetPostId = args["post_id"] as? Int
            case "create_comment":
                // Look up parent post from comment table
                if let cid = commentId {
                    targetPostId = commentParents[cid]
                } else {
                    targetPostId = nil
                }
            case "quote_post":
                targetPostId = args["quoted_id"] as? Int
            case "repost":
                targetPostId = args["reposted_id"] as? Int
            case "follow":
                targetPostId = args["followee_id"] as? Int
            default:
                targetPostId = args["post_id"] as? Int
            }

            let newPostId = args["new_post_id"] as? Int

            var action = OasisAction(
                agentId: trace.agentId,
                actionType: trace.action,
                round: trace.round,
                content: args["content"] as? String,
                targetPostId: targetPostId,
                targetCommentId: commentId,
                groupId: args["group_id"] as? Int,
                groupName: args["group_name"] as? String
            )
            if let newPostId {
                action.oasisNewPostId = newPostId
            }
            return action
        }

        // Clear existing data for this simulation
        try database.write { db in
            try db.execute(sql: "DELETE FROM social_group_message WHERE simulation_id = ?", arguments: [simulationId])
            try db.execute(sql: "DELETE FROM social_group_member WHERE simulation_id = ?", arguments: [simulationId])
            try db.execute(sql: "DELETE FROM social_group WHERE simulation_id = ?", arguments: [simulationId])
            try db.execute(sql: "DELETE FROM social_interaction WHERE simulation_id = ?", arguments: [simulationId])
            try db.execute(sql: "DELETE FROM social_connection WHERE simulation_id = ?", arguments: [simulationId])
            try db.execute(sql: "DELETE FROM social_post WHERE simulation_id = ?", arguments: [simulationId])
        }

        logger.info("Re-ingesting \(actions.count) actions for simulation \(simulationId.prefix(8), privacy: .public)")
        return try ingest(actions: actions, simulationId: simulationId, agentMapping: agentMapping)
    }

    // MARK: - Result

    struct IngestResult: Sendable {
        var postsCreated = 0
        var interactionsCreated = 0
        var connectionsCreated = 0

        var totalCreated: Int { postsCreated + interactionsCreated + connectionsCreated }
    }
}
