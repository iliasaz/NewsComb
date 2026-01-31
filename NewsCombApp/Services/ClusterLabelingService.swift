import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Generates LLM-powered titles and summaries for story theme clusters.
///
/// After HDBSCAN builds clusters with auto-generated labels (e.g., "Apple, Google — Competition"),
/// this service calls the analysis LLM to produce a human-readable headline and a brief summary
/// paragraph for each cluster. When no LLM is configured, the auto-generated labels are preserved.
final class ClusterLabelingService: Sendable {

    /// Status update during labeling.
    typealias StatusCallback = @MainActor @Sendable (String) -> Void

    /// Progress update with fraction complete (0..1).
    typealias ProgressCallback = @MainActor @Sendable (Double) -> Void

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "ClusterLabelingService")

    // MARK: - System Prompt

    private static let systemPrompt = """
        You are a concise news editor. Given a cluster of related news events, \
        produce a short headline and a brief summary paragraph.

        Rules:
        - The title must be under 10 words and specific (like a newspaper headline).
        - The summary must be exactly one paragraph of 2-4 sentences.
        - Focus on WHAT happened, WHO is involved, and WHY it matters.
        - Write in a neutral, factual news tone.

        Output EXACTLY this JSON: {"title": "...", "summary": "..."}
        """

    // MARK: - Public API

    /// Generates LLM titles and summaries for all clusters in a build.
    ///
    /// Clusters are processed sequentially to avoid overwhelming the LLM provider.
    /// Per-cluster errors are caught individually — the auto-label is preserved and the loop continues.
    ///
    /// - Parameters:
    ///   - buildId: The clustering build to label.
    ///   - statusCallback: Human-readable status updates.
    ///   - progressCallback: Fractional progress updates (0..1).
    func labelClusters(
        buildId: String,
        statusCallback: StatusCallback?,
        progressCallback: ProgressCallback?
    ) async {
        let settings: LLMSettings
        do {
            settings = try loadSettings()
        } catch {
            logger.warning("Failed to load settings, skipping LLM labeling: \(error.localizedDescription)")
            return
        }

        // If no analysis provider is configured, preserve auto-labels
        let provider = settings.effectiveAnalysisProvider
        guard !provider.isEmpty else {
            logger.info("No analysis LLM configured, preserving auto-labels")
            return
        }

        let clusters: [StoryCluster]
        do {
            clusters = try database.read { db in
                try StoryCluster
                    .filter(StoryCluster.Columns.buildId == buildId)
                    .order(StoryCluster.Columns.size.desc)
                    .fetchAll(db)
            }
        } catch {
            logger.error("Failed to load clusters for labeling: \(error.localizedDescription)")
            return
        }

        guard !clusters.isEmpty else {
            logger.info("No clusters to label for build \(buildId)")
            return
        }

        logger.info("Labeling \(clusters.count) clusters with LLM")

        for (index, cluster) in clusters.enumerated() {
            let fraction = Double(index) / Double(clusters.count)
            await progressCallback?(fraction)
            await statusCallback?("Generating theme summary \(index + 1)/\(clusters.count)\u{2026}")

            do {
                let exemplars = try loadExemplarSentences(clusterId: cluster.clusterId)
                let userPrompt = buildUserPrompt(
                    topEntities: cluster.topEntities,
                    topFamilies: cluster.topRelFamilies,
                    exemplarSentences: exemplars
                )

                let response = try await callLLM(
                    systemPrompt: Self.systemPrompt,
                    userPrompt: userPrompt,
                    settings: settings
                )

                let parsed = try parseResponse(response)

                try database.write { db in
                    try db.execute(
                        sql: """
                            UPDATE clusters SET label = ?, summary = ?
                            WHERE cluster_id = ? AND build_id = ?
                        """,
                        arguments: [parsed.title, parsed.summary, cluster.clusterId, buildId]
                    )
                }

                logger.info("Labeled cluster \(cluster.clusterId): \(parsed.title)")
            } catch {
                logger.warning(
                    "Failed to label cluster \(cluster.clusterId), preserving auto-label: \(error.localizedDescription)"
                )
            }
        }

        await progressCallback?(1.0)
    }

    // MARK: - Exemplar Loading

    /// Loads S-V-O sentences for a cluster's exemplar events.
    ///
    /// Joins `cluster_exemplars → hypergraph_edge → hypergraph_incidence → hypergraph_node`
    /// to produce sentences like `"Apple announces Vision Pro headset"`.
    private func loadExemplarSentences(clusterId: Int64) throws -> [String] {
        try database.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT
                    e.id AS edge_id,
                    e.label AS verb,
                    GROUP_CONCAT(
                        CASE WHEN i.role = 'subject' THEN n.label END
                    ) AS subjects,
                    GROUP_CONCAT(
                        CASE WHEN i.role = 'object' THEN n.label END
                    ) AS objects
                FROM cluster_exemplars ce
                JOIN hypergraph_edge e ON e.id = ce.event_id
                JOIN hypergraph_incidence i ON i.edge_id = e.id
                JOIN hypergraph_node n ON n.id = i.node_id
                WHERE ce.cluster_id = ?
                GROUP BY e.id, e.label
                ORDER BY ce.rank
                LIMIT 8
            """, arguments: [clusterId])

            return rows.compactMap { row -> String? in
                let verb: String = row["verb"]
                let subjects: String? = row["subjects"]
                let objects: String? = row["objects"]

                let subjectPart = subjects ?? "Unknown"
                let verbPart = verb
                let objectPart = objects.map { " \($0)" } ?? ""

                let sentence = "\(subjectPart) \(verbPart)\(objectPart)"
                return sentence.isEmpty ? nil : sentence
            }
        }
    }

    // MARK: - Prompt Building

    /// Builds the per-cluster user prompt from entities, relation families, and S-V-O sentences.
    func buildUserPrompt(
        topEntities: [RankedEntity],
        topFamilies: [RankedFamily],
        exemplarSentences: [String]
    ) -> String {
        let entities = topEntities.prefix(10).map(\.label).joined(separator: ", ")
        let families = topFamilies.prefix(5).map(\.family).joined(separator: ", ")
        let sentences = exemplarSentences.prefix(8)
            .enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n")

        return """
            Top entities: \(entities)

            Relation types: \(families)

            Key events:
            \(sentences)
            """
    }

    // MARK: - Response Parsing

    /// Parsed LLM response containing a title and summary.
    struct LabelResult: Sendable {
        let title: String
        let summary: String
    }

    /// Parses a JSON response from the LLM, stripping markdown code fences if present.
    func parseResponse(_ raw: String) throws -> LabelResult {
        // Strip markdown code fences (```json ... ``` or ``` ... ```)
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.hasPrefix("```") {
            // Remove opening fence (with optional language tag)
            if let firstNewline = cleaned.firstIndex(of: "\n") {
                cleaned = String(cleaned[cleaned.index(after: firstNewline)...])
            }
            // Remove closing fence
            if cleaned.hasSuffix("```") {
                cleaned = String(cleaned.dropLast(3))
            }
            cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        guard let data = cleaned.data(using: .utf8) else {
            throw LabelingError.invalidResponse("Could not encode response as UTF-8")
        }

        let decoded: [String: String]
        do {
            decoded = try JSONDecoder().decode([String: String].self, from: data)
        } catch {
            throw LabelingError.invalidResponse("Malformed JSON: \(error.localizedDescription)")
        }

        guard let title = decoded["title"], !title.isEmpty else {
            throw LabelingError.invalidResponse("Missing or empty 'title' field")
        }

        guard let summary = decoded["summary"], !summary.isEmpty else {
            throw LabelingError.invalidResponse("Missing or empty 'summary' field")
        }

        return LabelResult(title: title, summary: summary)
    }

    // MARK: - LLM Provider Routing

    /// Calls the analysis LLM using the configured provider.
    @MainActor
    private func callLLM(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        switch settings.effectiveAnalysisProvider {
        case "ollama":
            return try await callOllama(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        case "openrouter":
            return try await callOpenRouter(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        default:
            throw LabelingError.noProviderConfigured
        }
    }

    @MainActor
    private func callOllama(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        let endpoint = settings.effectiveAnalysisOllamaEndpoint ?? AppSettings.defaultAnalysisOllamaEndpoint
        let model = settings.effectiveAnalysisOllamaModel ?? AppSettings.defaultAnalysisOllamaModel

        guard let host = URL(string: endpoint) else {
            throw LabelingError.invalidConfiguration("Invalid Ollama endpoint: \(endpoint)")
        }

        let ollama = OllamaService(host: host, chatModel: model)
        return try await ollama.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: settings.analysisTemperature
        )
    }

    @MainActor
    private func callOpenRouter(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
            throw LabelingError.missingAPIKey
        }

        let model = settings.effectiveAnalysisOpenRouterModel ?? AppSettings.defaultAnalysisOpenRouterModel
        let openRouter = try OpenRouterService(apiKey: apiKey, model: model)
        return try await openRouter.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            temperature: settings.analysisTemperature
        )
    }

    // MARK: - Settings

    /// Loads LLM settings from the database (same pattern as DeepAnalysisService).
    private func loadSettings() throws -> LLMSettings {
        try database.read { db in
            var settings = LLMSettings()

            if let provider = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.llmProvider)
                .fetchOne(db) {
                settings.provider = provider.value
            }

            if let endpoint = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.ollamaEndpoint)
                .fetchOne(db) {
                settings.ollamaEndpoint = endpoint.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.ollamaModel)
                .fetchOne(db) {
                settings.ollamaModel = model.value
            }

            if let key = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.openRouterKey)
                .fetchOne(db) {
                settings.openRouterKey = key.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.openRouterModel)
                .fetchOne(db) {
                settings.openRouterModel = model.value
            }

            // Temperature configuration
            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.analysisTemperature)
                .fetchOne(db),
               let value = Double(setting.value) {
                settings.analysisTemperature = value
            }

            // Analysis LLM settings
            if let provider = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.analysisLLMProvider)
                .fetchOne(db) {
                settings.analysisProvider = provider.value
            }

            if let endpoint = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.analysisOllamaEndpoint)
                .fetchOne(db) {
                settings.analysisOllamaEndpoint = endpoint.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.analysisOllamaModel)
                .fetchOne(db) {
                settings.analysisOllamaModel = model.value
            }

            if let model = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.analysisOpenRouterModel)
                .fetchOne(db) {
                settings.analysisOpenRouterModel = model.value
            }

            return settings
        }
    }
}

// MARK: - Errors

enum LabelingError: Error, LocalizedError {
    case noProviderConfigured
    case missingAPIKey
    case invalidConfiguration(String)
    case invalidResponse(String)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            "No LLM provider configured for cluster labeling."
        case .missingAPIKey:
            "OpenRouter API key is missing."
        case .invalidConfiguration(let message):
            "Invalid LLM configuration: \(message)"
        case .invalidResponse(let message):
            "Invalid LLM response: \(message)"
        }
    }
}
