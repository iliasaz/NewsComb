import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Generates insight reports from simulation results using a two-agent LLM workflow.
///
/// Follows the `DeepAnalysisService` pattern:
/// 1. **Analyst Agent**: examines posts, interactions, network structure
/// 2. **Insight Agent**: identifies narratives, consensus/contention, influential agents
final class SimulationReportService: Sendable {

    private let database = Database.current
    private let graphService = SocialGraphService()
    private let logger = Logger(subsystem: "com.newscomb", category: "SimulationReportService")

    // MARK: - Callbacks

    typealias StatusCallback = @MainActor @Sendable (String) -> Void
    typealias TokenCallback = @MainActor @Sendable (String) -> Void

    // MARK: - Public API

    /// Generates a report for a completed simulation.
    func generateReport(
        simulationId: String,
        statusCallback: StatusCallback? = nil,
        analysisTokenCallback: TokenCallback? = nil,
        insightTokenCallback: TokenCallback? = nil
    ) async throws -> SimulationReport {
        logger.info("Generating report for simulation \(simulationId, privacy: .public)")

        // Gather simulation data
        await statusCallback?("Gathering simulation data\u{2026}")
        let data = try gatherData(simulationId: simulationId)

        let settings = try loadSettings()

        // Step 1: Analyst Agent
        await statusCallback?("Running Analyst agent\u{2026}")
        let analysis = try await generateWithLLM(
            systemPrompt: analystSystemPrompt,
            userPrompt: formatAnalystPrompt(data: data),
            settings: settings,
            tokenCallback: analysisTokenCallback
        )

        // Step 2: Insight Agent
        await statusCallback?("Running Insight agent\u{2026}")
        let insights = try await generateWithLLM(
            systemPrompt: insightSystemPrompt,
            userPrompt: formatInsightPrompt(data: data, analysis: analysis),
            settings: settings,
            tokenCallback: insightTokenCallback
        )

        await statusCallback?("Report complete")
        return SimulationReport(analysis: analysis, insights: insights)
    }

    // MARK: - Data Gathering

    private struct ReportData {
        let stats: SocialGraphService.SimulationStats
        let agents: [SocialAgent]
        let topPosts: [SocialPost]
        let interactionSummary: [String: Int]
        let postCounts: [Int64: Int]
    }

    private func gatherData(simulationId: String) throws -> ReportData {
        let stats = try graphService.stats(simulationId: simulationId)
        let agents = try graphService.agents(for: simulationId)
        let topPosts = try graphService.posts(simulationId: simulationId, limit: 30)
        let interactionSummary = try graphService.interactionSummary(simulationId: simulationId)
        let postCounts = try graphService.postCounts(simulationId: simulationId)

        return ReportData(
            stats: stats,
            agents: agents,
            topPosts: topPosts,
            interactionSummary: interactionSummary,
            postCounts: postCounts
        )
    }

    // MARK: - Prompts

    private let analystSystemPrompt = """
        You are a social media analyst examining the results of a simulated social network \
        discourse about news topics. Analyze the data provided and produce a structured \
        analysis covering: key topics discussed, interaction patterns, agent behavior, \
        and notable dynamics. Use markdown formatting.
        """

    private let insightSystemPrompt = """
        You are a strategic insight analyst. Based on the simulation analysis provided, \
        identify actionable insights including: emergent narratives, points of consensus \
        and contention, most influential agents and why, surprising behaviors, and \
        implications for real-world discourse. Be specific and reference the data. \
        Use markdown formatting.
        """

    private func formatAnalystPrompt(data: ReportData) -> String {
        let agentList = data.agents.prefix(20).map { agent in
            let count = data.postCounts[agent.id!] ?? 0
            return "- \(agent.displayName) (\(count) posts): \(agent.bio)"
        }.joined(separator: "\n")

        let postSamples = data.topPosts.prefix(15).map { post in
            let agent = data.agents.first { $0.id == post.agentId }
            return "[\(agent?.displayName ?? "?")] \(post.content)"
        }.joined(separator: "\n\n")

        let interactions = data.interactionSummary.map { "\($0.key): \($0.value)" }.joined(separator: ", ")

        return """
            ## Simulation Statistics
            - Agents: \(data.stats.agentCount)
            - Posts: \(data.stats.postCount)
            - Interactions: \(data.stats.interactionCount)
            - Connections: \(data.stats.connectionCount)
            - Rounds completed: \(data.stats.latestRound)

            ## Interaction Breakdown
            \(interactions)

            ## Agents
            \(agentList)

            ## Sample Posts (most recent)
            \(postSamples)

            Please analyze these simulation results.
            """
    }

    private func formatInsightPrompt(data: ReportData, analysis: String) -> String {
        """
        ## Previous Analysis
        \(analysis)

        ## Raw Statistics
        - \(data.stats.agentCount) agents, \(data.stats.postCount) posts, \(data.stats.latestRound) rounds

        Based on this analysis, identify key insights and implications.
        """
    }

    // MARK: - LLM Integration

    @MainActor
    private func generateWithLLM(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings,
        tokenCallback: TokenCallback?
    ) async throws -> String {
        switch settings.effectiveAnalysisProvider {
        case "ollama":
            let endpoint = settings.effectiveAnalysisOllamaEndpoint ?? AppSettings.defaultAnalysisOllamaEndpoint
            let model = settings.effectiveAnalysisOllamaModel ?? AppSettings.defaultAnalysisOllamaModel
            guard let host = URL(string: endpoint) else {
                throw ReportError.invalidConfiguration
            }
            let ollama = OllamaService(host: host, chatModel: model)
            if let tokenCallback {
                return try await ollama.chatStream(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: nil,
                    temperature: 0.5,
                    onToken: { token in Task { @MainActor in tokenCallback(token) } }
                )
            }
            return try await ollama.chat(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: nil,
                temperature: 0.5
            )

        case "openrouter":
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                throw ReportError.invalidConfiguration
            }
            let model = settings.analysisOpenRouterModel ?? settings.openRouterModel ?? "meta-llama/llama-4-maverick"
            let openRouter = try OpenRouterService(apiKey: apiKey, model: model, timeout: .seconds(600))
            if let tokenCallback {
                return try await openRouter.chatStream(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: nil,
                    temperature: 0.5,
                    onToken: { token in Task { @MainActor in tokenCallback(token) } }
                )
            }
            return try await openRouter.chat(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: nil,
                temperature: 0.5
            )

        default:
            throw ReportError.invalidConfiguration
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

// MARK: - Types

struct SimulationReport: Sendable {
    let analysis: String
    let insights: String
}

enum ReportError: LocalizedError {
    case invalidConfiguration

    var errorDescription: String? {
        "LLM provider not configured. Check Settings."
    }
}
