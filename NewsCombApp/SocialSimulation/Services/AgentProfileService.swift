import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Generates social agent profiles from hypergraph persona-nodes.
///
/// Reads from the knowledge hypergraph (nodes, edges, incidences, provenance,
/// embeddings, clusters) in read-only mode. Writes only to `social_agent`
/// and `social_connection` tables.
final class AgentProfileService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "AgentProfileService")

    // MARK: - Callbacks

    typealias StatusCallback = @MainActor @Sendable (String) -> Void
    typealias ProgressCallback = @MainActor @Sendable (Double) -> Void

    // MARK: - Persona Node Types

    /// Node types that represent actor entities suitable for social simulation.
    /// Excludes "non-actor" nodes (products, concepts, events, etc.) which provide
    /// context for agents but do not act on the platform themselves.
    static let personaNodeTypes: Set<String> = [
        "person", "organization", "company", "government_entity", "institution"
    ]

    // MARK: - Public API

    /// Generates agent profiles for the given simulation from selected hypergraph nodes.
    ///
    /// - Parameters:
    ///   - simulationId: The simulation to create agents for.
    ///   - nodeIds: Specific hypergraph node IDs to create agents from.
    ///     If empty, automatically selects persona-type nodes with sufficient context.
    ///   - maxAgents: Maximum number of agents to generate.
    ///   - statusCallback: Called with human-readable status updates.
    ///   - progressCallback: Called with progress (0.0 to 1.0).
    /// - Returns: The created social agents.
    func generateProfiles(
        simulationId: String,
        nodeIds: [Int64] = [],
        maxAgents: Int = 30,
        statusCallback: StatusCallback? = nil,
        progressCallback: ProgressCallback? = nil
    ) async throws -> [SocialAgent] {
        logger.info("Generating profiles for simulation \(simulationId, privacy: .public)")

        // Step 1: Select persona nodes
        await statusCallback?("Selecting persona nodes\u{2026}")
        let selectedNodes: [HypergraphNode]
        if nodeIds.isEmpty {
            selectedNodes = try selectPersonaNodes(maxCount: maxAgents)
        } else {
            selectedNodes = try fetchNodes(ids: nodeIds, maxCount: maxAgents)
        }

        // Count total available persona nodes for logging
        let totalPersonaCount = try database.read { db in
            let personaTypes = Self.personaNodeTypes.map { "'\($0)'" }.joined(separator: ", ")
            return try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM hypergraph_node
                WHERE LOWER(node_type) IN (\(personaTypes))
                """) ?? 0
        }

        guard !selectedNodes.isEmpty else {
            throw AgentProfileError.noPersonaNodesFound
        }

        logger.info("Selected \(selectedNodes.count) persona nodes out of \(totalPersonaCount) available")
        await statusCallback?("Selected \(selectedNodes.count) of \(totalPersonaCount) persona nodes")

        // Step 2: Generate profiles via LLM
        await statusCallback?("Generating agent personas\u{2026}")
        let settings = try loadSettings()
        var agents: [SocialAgent] = []

        for (index, node) in selectedNodes.enumerated() {
            let context = try assembleNodeContext(for: node)

            let persona = try await generatePersona(
                node: node,
                context: context,
                settings: settings
            )

            let personaData = try JSONEncoder().encode(persona)
            let personaJson = String(data: personaData, encoding: .utf8)

            let agent = SocialAgent(
                nodeId: node.id!,
                displayName: persona.profession != nil
                    ? "\(node.label)"
                    : node.label,
                bio: buildBio(node: node, persona: persona),
                personaJson: personaJson,
                simulationId: simulationId,
                oasisUserId: index
            )

            try database.write { db in
                try agent.insert(db)
            }

            agents.append(agent)

            let progress = Double(index + 1) / Double(selectedNodes.count)
            await progressCallback?(progress)
            logger.info("Generated profile \(index + 1)/\(selectedNodes.count): \(node.label, privacy: .public)")
        }

        // Step 3: Build initial social graph from hypergraph co-occurrence
        await statusCallback?("Building social connections\u{2026}")
        try buildInitialSocialGraph(agents: agents, simulationId: simulationId)

        // Update agent count
        try database.write { db in
            try db.execute(
                sql: "UPDATE social_simulation SET agent_count = ? WHERE id = ?",
                arguments: [agents.count, simulationId]
            )
        }

        logger.info("Profile generation complete: \(agents.count) agents")
        return agents
    }

    // MARK: - Node Selection

    /// Proportion of "person" nodes in the agent selection (0.0–1.0).
    /// The remainder is filled with organization, company, government_entity, and institution nodes.
    private static let personRatio: Double = 0.8

    /// Selects hypergraph nodes that represent personas with sufficient context.
    ///
    /// Targets ~80% individuals and ~20% organizations/companies/government/institutions,
    /// filling each bucket from the most-connected nodes of that type.
    /// Falls back to most-connected nodes regardless of type if no typed nodes exist.
    private func selectPersonaNodes(maxCount: Int) throws -> [HypergraphNode] {
        try database.read { db in
            let personaTypes = Self.personaNodeTypes.map { "'\($0)'" }.joined(separator: ", ")
            let connectedSQL = """
                SELECT n.*
                FROM hypergraph_node n
                JOIN hypergraph_incidence i ON i.node_id = n.id
                WHERE LOWER(n.node_type) IN (\(personaTypes))
                GROUP BY n.id
                HAVING COUNT(DISTINCT i.edge_id) >= 2
                ORDER BY COUNT(DISTINCT i.edge_id) DESC
                """
            let allTyped = try HypergraphNode.fetchAll(db, sql: connectedSQL)

            guard !allTyped.isEmpty else {
                // Fallback: select most connected nodes regardless of type.
                logger.info("No typed persona nodes found, falling back to most connected nodes")
                let fallbackSQL = """
                    SELECT n.*
                    FROM hypergraph_node n
                    JOIN hypergraph_incidence i ON i.node_id = n.id
                    WHERE LENGTH(n.label) <= 80
                    GROUP BY n.id
                    HAVING COUNT(DISTINCT i.edge_id) >= 1
                    ORDER BY COUNT(DISTINCT i.edge_id) DESC
                    LIMIT ?
                    """
                return try HypergraphNode.fetchAll(db, sql: fallbackSQL, arguments: [maxCount])
            }

            // Split into persons vs organizations/companies/etc.
            let persons = allTyped.filter { $0.nodeType?.lowercased() == "person" }
            let orgs = allTyped.filter { $0.nodeType?.lowercased() != "person" }

            let personTarget = Int(ceil(Double(maxCount) * Self.personRatio))
            let orgTarget = maxCount - personTarget

            var selected: [HypergraphNode] = []
            selected.append(contentsOf: persons.prefix(personTarget))

            let remainingSlots = maxCount - selected.count
            selected.append(contentsOf: orgs.prefix(max(orgTarget, remainingSlots)))

            // If we still haven't filled maxCount, top up from whichever pool has more
            if selected.count < maxCount {
                let usedIds = Set(selected.compactMap(\.id))
                let remaining = allTyped.filter { !usedIds.contains($0.id!) }
                selected.append(contentsOf: remaining.prefix(maxCount - selected.count))
            }

            logger.info("Selected \(selected.count) persona nodes: \(selected.filter { $0.nodeType?.lowercased() == "person" }.count) persons, \(selected.filter { $0.nodeType?.lowercased() != "person" }.count) orgs")
            return Array(selected.prefix(maxCount))
        }
    }

    /// Fetches specific nodes by ID.
    private func fetchNodes(ids: [Int64], maxCount: Int) throws -> [HypergraphNode] {
        try database.read { db in
            try HypergraphNode
                .filter(ids.contains(HypergraphNode.Columns.id))
                .limit(maxCount)
                .fetchAll(db)
        }
    }

    // MARK: - Context Assembly (Read-Only from Hypergraph)

    /// Assembles rich context for a node from the knowledge hypergraph.
    ///
    /// Reads edges, provenance chunk text, and cluster themes — never writes.
    private func assembleNodeContext(for node: HypergraphNode) throws -> NodeContext {
        try database.read { db in
            // Get all S-V-O triples involving this node, with provenance text
            let triplesSQL = """
                SELECT e.label AS edge_label,
                       src_n.label AS source_label,
                       tgt_n.label AS target_label,
                       p.chunk_text
                FROM hypergraph_incidence i
                JOIN hypergraph_edge e ON e.id = i.edge_id
                LEFT JOIN hypergraph_incidence src_i ON src_i.edge_id = e.id AND src_i.role = 'source'
                LEFT JOIN hypergraph_node src_n ON src_n.id = src_i.node_id
                LEFT JOIN hypergraph_incidence tgt_i ON tgt_i.edge_id = e.id AND tgt_i.role = 'target'
                LEFT JOIN hypergraph_node tgt_n ON tgt_n.id = tgt_i.node_id
                LEFT JOIN article_edge_provenance p ON p.edge_id = e.id
                WHERE i.node_id = ?
                ORDER BY e.id DESC
                LIMIT 30
                """
            let rows = try Row.fetchAll(db, sql: triplesSQL, arguments: [node.id])

            var triples: [Triple] = []
            var provenanceTexts: [String] = []

            for row in rows {
                let triple = Triple(
                    source: row["source_label"] ?? "",
                    relation: row["edge_label"] ?? "",
                    target: row["target_label"] ?? ""
                )
                triples.append(triple)

                if let chunkText: String = row["chunk_text"], !chunkText.isEmpty {
                    provenanceTexts.append(chunkText)
                }
            }

            // Get cluster themes this node participates in
            let clusterSQL = """
                SELECT c.label, c.summary
                FROM clusters c
                JOIN cluster_members cm ON cm.cluster_id = c.cluster_id
                JOIN event_cluster ec ON ec.event_id = cm.event_id
                JOIN hypergraph_incidence i ON i.edge_id = ec.event_id
                WHERE i.node_id = ?
                GROUP BY c.cluster_id
                LIMIT 5
                """
            let clusterRows = try Row.fetchAll(db, sql: clusterSQL, arguments: [node.id])
            let themes = clusterRows.compactMap { row -> String? in
                let label: String? = row["label"]
                let summary: String? = row["summary"]
                return label ?? summary
            }

            return NodeContext(
                triples: triples,
                provenanceTexts: Array(Set(provenanceTexts).prefix(10)),
                themes: themes
            )
        }
    }

    // MARK: - LLM Profile Generation

    /// Generates a persona via LLM from the node's knowledge graph context.
    private func generatePersona(
        node: HypergraphNode,
        context: NodeContext,
        settings: LLMSettings
    ) async throws -> AgentPersona {
        let triplesFormatted = context.triples.prefix(15).map { triple in
            "\(triple.source) → \(triple.relation) → \(triple.target)"
        }.joined(separator: "\n")

        let provenanceFormatted = context.provenanceTexts.prefix(5).map { text in
            "> \(text.prefix(300))"
        }.joined(separator: "\n\n")

        let themesFormatted = context.themes.isEmpty
            ? "None identified"
            : context.themes.joined(separator: ", ")

        let systemPrompt = try loadProfilePrompt()

        let userPrompt = """
            Entity: \(node.label)
            Type: \(node.nodeType ?? "unknown")

            Known relationships:
            \(triplesFormatted)

            Source context from news articles:
            \(provenanceFormatted)

            Related news themes: \(themesFormatted)

            Generate a persona JSON with these fields:
            {
              "age": <integer or null if organization>,
              "profession": "<role or sector>",
              "interests": ["<topic1>", "<topic2>", ...],
              "mbti": "<4-letter type or null>",
              "sentimentBias": <float -1.0 to 1.0, based on the entity's typical stance>,
              "stance": "<brief description of known positions or outlook>",
              "influenceWeight": <float 0.0 to 1.0, based on prominence>
            }
            """

        let response = try await generateWithLLM(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            settings: settings
        )

        // Parse JSON from response (handle markdown code blocks)
        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            throw AgentProfileError.invalidPersonaResponse
        }

        do {
            return try JSONDecoder().decode(AgentPersona.self, from: data)
        } catch {
            // Fallback: create a basic persona from what we know
            logger.warning("Failed to parse LLM persona, using fallback: \(error.localizedDescription, privacy: .public)")
            return AgentPersona(
                profession: node.nodeType,
                interests: context.themes,
                influenceWeight: min(1.0, Double(node.idf ?? 1.0) / 6.0)
            )
        }
    }

    // MARK: - Social Graph Construction

    /// Builds initial follow relationships from hypergraph co-occurrence.
    ///
    /// Two agents get a connection if their source nodes co-occur in the same
    /// hyperedge (S-V-O triple). All connections are written to `social_connection`
    /// with `source = "initial"`.
    private func buildInitialSocialGraph(agents: [SocialAgent], simulationId: String) throws {
        // Build a lookup from node_id to agent
        let nodeToAgent = Dictionary(uniqueKeysWithValues: agents.compactMap { agent -> (Int64, SocialAgent)? in
            guard agent.id != nil else { return nil }
            return (agent.nodeId, agent)
        })

        // Find co-occurrences: pairs of nodes that appear in the same edge
        let cooccurrences = try database.read { db -> Set<String> in
            let nodeIds = agents.map(\.nodeId)
            guard nodeIds.count >= 2 else { return [] }

            let placeholders = nodeIds.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                SELECT DISTINCT i1.node_id AS node1, i2.node_id AS node2
                FROM hypergraph_incidence i1
                JOIN hypergraph_incidence i2 ON i1.edge_id = i2.edge_id AND i1.node_id < i2.node_id
                WHERE i1.node_id IN (\(placeholders)) AND i2.node_id IN (\(placeholders))
                """
            let args = nodeIds + nodeIds
            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

            var pairs: Set<String> = []
            for row in rows {
                let node1: Int64 = row["node1"]
                let node2: Int64 = row["node2"]
                pairs.insert("\(node1)-\(node2)")
            }
            return pairs
        }

        // Create bidirectional connections for co-occurring nodes
        try database.write { db in
            for pairKey in cooccurrences {
                let parts = pairKey.split(separator: "-").compactMap { Int64($0) }
                guard parts.count == 2,
                      let agent1 = nodeToAgent[parts[0]], let id1 = agent1.id,
                      let agent2 = nodeToAgent[parts[1]], let id2 = agent2.id else {
                    continue
                }

                // Bidirectional follow
                let conn1 = SocialConnection(
                    followerId: id1,
                    followeeId: id2,
                    source: "initial",
                    simulationId: simulationId
                )
                try conn1.insert(db)

                let conn2 = SocialConnection(
                    followerId: id2,
                    followeeId: id1,
                    source: "initial",
                    simulationId: simulationId
                )
                try conn2.insert(db)
            }
        }

        let connectionCount = try database.read { db in
            try SocialConnection
                .filter(SocialConnection.Columns.simulationId == simulationId)
                .fetchCount(db)
        }
        logger.info("Built initial social graph: \(connectionCount) connections from co-occurrence")
    }

    // MARK: - Helpers

    private func buildBio(node: HypergraphNode, persona: AgentPersona) -> String {
        var parts: [String] = []
        if let profession = persona.profession {
            parts.append(profession)
        }
        if !persona.interests.isEmpty {
            parts.append("Interests: \(persona.interests.prefix(3).joined(separator: ", "))")
        }
        if let stance = persona.stance, !stance.isEmpty {
            parts.append(stance)
        }
        return parts.isEmpty ? node.label : parts.joined(separator: ". ")
    }

    /// Extracts JSON from an LLM response that may include markdown code blocks.
    private func extractJSON(from response: String) -> String {
        // Try to extract from ```json ... ``` blocks
        if let jsonStart = response.range(of: "```json"),
           let jsonEnd = response.range(of: "```", range: jsonStart.upperBound..<response.endIndex) {
            return String(response[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to extract from ``` ... ``` blocks
        if let jsonStart = response.range(of: "```"),
           let jsonEnd = response.range(of: "```", range: jsonStart.upperBound..<response.endIndex) {
            return String(response[jsonStart.upperBound..<jsonEnd.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Try to find raw JSON object
        if let braceStart = response.firstIndex(of: "{"),
           let braceEnd = response.lastIndex(of: "}") {
            return String(response[braceStart...braceEnd])
        }
        return response
    }

    // MARK: - LLM Integration

    private func generateWithLLM(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        switch settings.effectiveAnalysisProvider {
        case "ollama":
            let endpoint = settings.effectiveAnalysisOllamaEndpoint ?? AppSettings.defaultAnalysisOllamaEndpoint
            let model = settings.effectiveAnalysisOllamaModel ?? AppSettings.defaultAnalysisOllamaModel
            guard let host = URL(string: endpoint) else {
                throw AgentProfileError.invalidConfiguration("Invalid Ollama endpoint")
            }
            let ollama = await OllamaService(host: host, chatModel: model)
            return try await ollama.chat(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: nil,
                temperature: settings.analysisTemperature
            )
        case "openrouter":
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                throw AgentProfileError.invalidConfiguration("OpenRouter API key not configured")
            }
            let model = settings.analysisOpenRouterModel ?? settings.openRouterModel ?? "meta-llama/llama-4-maverick"
            let openRouter = try OpenRouterService(apiKey: apiKey, model: model)
            return try await openRouter.chat(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: nil,
                temperature: settings.analysisTemperature
            )
        default:
            throw AgentProfileError.invalidConfiguration("No LLM provider configured")
        }
    }

    /// Loads the profile generation system prompt from persisted settings.
    private func loadProfilePrompt() throws -> String {
        try database.read { db in
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.simProfilePrompt)
                .fetchOne(db) {
                return setting.value
            }
            return AppSettings.defaultSimProfilePrompt
        }
    }

    private func loadSettings() throws -> LLMSettings {
        try database.read { db in
            var settings = LLMSettings()

            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.llmProvider).fetchOne(db) {
                settings.provider = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.ollamaEndpoint).fetchOne(db) {
                settings.ollamaEndpoint = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.ollamaModel).fetchOne(db) {
                settings.ollamaModel = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterKey).fetchOne(db) {
                settings.openRouterKey = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterModel).fetchOne(db) {
                settings.openRouterModel = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisLLMProvider).fetchOne(db) {
                settings.analysisProvider = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisOllamaEndpoint).fetchOne(db) {
                settings.analysisOllamaEndpoint = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisOllamaModel).fetchOne(db) {
                settings.analysisOllamaModel = s.value
            }
            if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisOpenRouterModel).fetchOne(db) {
                settings.analysisOpenRouterModel = s.value
            }

            return settings
        }
    }
}

// MARK: - Supporting Types

extension AgentProfileService {

    struct NodeContext: Sendable {
        let triples: [Triple]
        let provenanceTexts: [String]
        let themes: [String]
    }

    struct Triple: Sendable {
        let source: String
        let relation: String
        let target: String
    }
}

// MARK: - Errors

enum AgentProfileError: LocalizedError {
    case noPersonaNodesFound
    case invalidPersonaResponse
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .noPersonaNodesFound:
            "No persona-type nodes found in the knowledge graph. Process some news articles first."
        case .invalidPersonaResponse:
            "Failed to parse persona from LLM response."
        case .invalidConfiguration(let detail):
            "Invalid configuration: \(detail)"
        }
    }
}
