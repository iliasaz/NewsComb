import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Handles agent interviews — either via IPC to the running OASIS subprocess
/// or via direct LLM call when OASIS is stopped.
final class AgentInterviewService: Sendable {

    private let database = Database.current
    private let graphService = SocialGraphService()
    private let logger = Logger(subsystem: "com.newscomb", category: "AgentInterviewService")

    // MARK: - Callbacks

    typealias TokenCallback = @MainActor @Sendable (String) -> Void

    // MARK: - Public API

    /// Conducts an interview turn with an agent.
    ///
    /// - Parameters:
    ///   - agent: The agent to interview.
    ///   - prompt: The user's question.
    ///   - conversationHistory: Previous messages in this conversation.
    ///   - engine: The simulation engine (if running, uses IPC).
    ///   - tokenCallback: Called with each token during LLM streaming (fallback path only).
    /// - Returns: The agent's response.
    func interview(
        agent: SocialAgent,
        prompt: String,
        conversationHistory: [AgentInterview.Message] = [],
        engine: SimulationEngine? = nil,
        tokenCallback: TokenCallback? = nil
    ) async throws -> String {
        // Primary path: IPC to running OASIS subprocess
        if let engine, await engine.currentStatus.isActive {
            if let oasisId = agent.oasisUserId {
                do {
                    let response = try await engine.interviewAgent(agentId: oasisId, prompt: prompt)
                    logger.info("IPC interview completed for agent \(agent.displayName, privacy: .public)")
                    return response
                } catch {
                    logger.warning("IPC interview failed, falling back to LLM: \(error.localizedDescription, privacy: .public)")
                }
            }
        }

        // Fallback path: direct LLM call with assembled context
        return try await interviewViaLLM(
            agent: agent,
            prompt: prompt,
            conversationHistory: conversationHistory,
            tokenCallback: tokenCallback
        )
    }

    /// Persists a conversation to the database.
    func saveConversation(
        agentId: Int64,
        messages: [AgentInterview.Message],
        simulationId: String
    ) throws {
        let messagesData = try JSONEncoder().encode(messages)
        let messagesJson = String(data: messagesData, encoding: .utf8) ?? "[]"

        try database.write { db in
            let interview = AgentInterview(
                agentId: agentId,
                messagesJson: messagesJson,
                simulationId: simulationId
            )
            try interview.insert(db)
        }
    }

    /// Loads previous interviews for an agent.
    func loadInterviews(agentId: Int64) throws -> [AgentInterview] {
        try database.read { db in
            try AgentInterview
                .filter(AgentInterview.Columns.agentId == agentId)
                .order(AgentInterview.Columns.createdAt.desc)
                .fetchAll(db)
        }
    }

    // MARK: - LLM Fallback

    @MainActor
    private func interviewViaLLM(
        agent: SocialAgent,
        prompt: String,
        conversationHistory: [AgentInterview.Message],
        tokenCallback: TokenCallback?
    ) async throws -> String {
        let systemPrompt = try buildSystemPrompt(for: agent)
        let userPrompt = buildUserPrompt(prompt: prompt, history: conversationHistory)
        let settings = try loadSettings()

        logger.info("LLM fallback interview for agent \(agent.displayName, privacy: .public)")

        switch settings.effectiveAnalysisProvider {
        case "ollama":
            let endpoint = settings.effectiveAnalysisOllamaEndpoint ?? AppSettings.defaultAnalysisOllamaEndpoint
            let model = settings.effectiveAnalysisOllamaModel ?? AppSettings.defaultAnalysisOllamaModel
            guard let host = URL(string: endpoint) else {
                throw InterviewError.invalidConfiguration("Invalid Ollama endpoint")
            }
            let ollama = OllamaService(host: host, chatModel: model)

            if let tokenCallback {
                return try await ollama.chatStream(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: nil,
                    temperature: 0.7,
                    onToken: { token in Task { @MainActor in tokenCallback(token) } }
                )
            }

            return try await ollama.chat(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: nil,
                temperature: 0.7
            )

        case "openrouter":
            guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
                throw InterviewError.invalidConfiguration("OpenRouter API key not configured")
            }
            let model = settings.analysisOpenRouterModel ?? settings.openRouterModel ?? "meta-llama/llama-4-maverick"
            let openRouter = try OpenRouterService(apiKey: apiKey, model: model)

            if let tokenCallback {
                return try await openRouter.chatStream(
                    systemPrompt: systemPrompt,
                    userPrompt: userPrompt,
                    model: nil,
                    temperature: 0.7,
                    onToken: { token in Task { @MainActor in tokenCallback(token) } }
                )
            }

            return try await openRouter.chat(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: nil,
                temperature: 0.7
            )

        default:
            throw InterviewError.invalidConfiguration("No LLM provider configured")
        }
    }

    // MARK: - Prompt Construction

    private func buildSystemPrompt(for agent: SocialAgent) throws -> String {
        let knowledgeContext = try graphService.knowledgeContext(for: agent)

        // Get agent's simulation posts
        let posts = try graphService.posts(byAgentId: agent.id!)
        let recentPosts = posts.prefix(10).map { "- \($0.content)" }.joined(separator: "\n")

        let persona = agent.persona
        let personaDetails = [
            persona?.profession.map { "Profession: \($0)" },
            persona?.stance.map { "Stance: \($0)" },
            persona?.interests.isEmpty == false ? "Interests: \(persona!.interests.joined(separator: ", "))" : nil,
            persona?.mbti.map { "Personality type: \($0)" }
        ].compactMap { $0 }.joined(separator: "\n")

        return """
            You are \(agent.displayName). \(agent.bio)

            \(personaDetails)

            Your knowledge from news sources:
            \(knowledgeContext)

            \(recentPosts.isEmpty ? "" : "Your recent social media posts:\n\(recentPosts)")

            Respond to the interviewer's questions in character. Draw on your knowledge, \
            experiences, and personality. Be authentic to your persona. Keep responses \
            conversational and natural.
            """
    }

    private func buildUserPrompt(prompt: String, history: [AgentInterview.Message]) -> String {
        if history.isEmpty {
            return prompt
        }

        var formatted = "Previous conversation:\n"
        for message in history.suffix(6) {
            let role = message.role == "user" ? "Interviewer" : "You"
            formatted += "\(role): \(message.content)\n\n"
        }
        formatted += "Interviewer: \(prompt)"
        return formatted
    }

    // MARK: - Settings

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

// MARK: - Errors

enum InterviewError: LocalizedError {
    case invalidConfiguration(String)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            "Interview configuration error: \(detail)"
        }
    }
}
