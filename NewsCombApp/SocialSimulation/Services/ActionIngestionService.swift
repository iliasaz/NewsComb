import Foundation
import GRDB
import OSLog

/// Maps OASIS action log entries to NewsComb social graph records.
///
/// Stateless service that transforms `OasisAction` batches into `SocialPost`,
/// `SocialInteraction`, and `SocialConnection` records. Writes only to the
/// social graph tables, never to the knowledge hypergraph.
final class ActionIngestionService: Sendable {

    private let database = Database.shared
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
                    var post = SocialPost(
                        agentId: agentId,
                        content: content,
                        simTimestamp: simTimestamp,
                        roundNum: roundNum,
                        platform: "twitter",
                        simulationId: simulationId
                    )
                    try post.insert(db)
                    result.postsCreated += 1

                case "create_comment", "CREATE_COMMENT":
                    guard let content = action.content else { continue }
                    let parentId = resolvePostId(oasisPostId: action.targetPostId, simulationId: simulationId, db: db)
                    var post = SocialPost(
                        agentId: agentId,
                        content: content,
                        parentPostId: parentId,
                        simTimestamp: simTimestamp,
                        roundNum: roundNum,
                        platform: "twitter",
                        simulationId: simulationId
                    )
                    try post.insert(db)
                    result.postsCreated += 1

                case "repost", "REPOST", "quote_post", "QUOTE_POST":
                    let repostOfId = resolvePostId(oasisPostId: action.targetPostId, simulationId: simulationId, db: db)
                    let content = action.content ?? ""
                    var post = SocialPost(
                        agentId: agentId,
                        content: content,
                        repostOfId: repostOfId,
                        simTimestamp: simTimestamp,
                        roundNum: roundNum,
                        platform: "twitter",
                        simulationId: simulationId
                    )
                    try post.insert(db)
                    result.postsCreated += 1

                case "like_post", "LIKE_POST", "like_comment", "LIKE_COMMENT":
                    let postId = resolvePostId(oasisPostId: action.targetPostId, simulationId: simulationId, db: db)
                    var interaction = SocialInteraction(
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

                case "do_nothing", "DO_NOTHING":
                    break

                default:
                    // Unknown action type — record as interaction
                    if let actionType = action.actionType {
                        var interaction = SocialInteraction(
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

    // MARK: - Result

    struct IngestResult: Sendable {
        var postsCreated = 0
        var interactionsCreated = 0
        var connectionsCreated = 0

        var totalCreated: Int { postsCreated + interactionsCreated + connectionsCreated }
    }
}
