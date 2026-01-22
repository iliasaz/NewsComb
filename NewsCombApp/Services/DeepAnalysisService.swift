import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Service that orchestrates the "Dive Deeper" multi-agent analysis workflow.
///
/// This service simulates a multi-agent architecture using sequential LLM calls,
/// inspired by the Python AutoGen reference implementation. The workflow is:
///
/// 1. **Engineer Agent**: Synthesizes the initial answer with academic-style citations
/// 2. **Hypothesizer Agent**: Generates hypotheses and experiment suggestions
///
/// The agents work sequentially, with each building on the previous output.
final class DeepAnalysisService: Sendable {

    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "DeepAnalysisService")

    // MARK: - Public API

    /// Performs deep analysis on an existing GraphRAG response using simulated multi-agent workflow.
    ///
    /// - Parameters:
    ///   - question: The original user question
    ///   - initialAnswer: The initial GraphRAG answer
    ///   - relatedNodes: Nodes related to the query
    ///   - reasoningPaths: Multi-hop reasoning paths between concepts
    ///   - graphPaths: Direct graph relationships
    /// - Returns: A `DeepAnalysisResult` with synthesized answer and hypotheses
    @MainActor
    func analyze(
        question: String,
        initialAnswer: String,
        relatedNodes: [GraphRAGResponse.RelatedNode],
        reasoningPaths: [GraphRAGResponse.ReasoningPath],
        graphPaths: [GraphRAGResponse.GraphPath]
    ) async throws -> DeepAnalysisResult {
        logger.info("Starting deep analysis for question: \(question, privacy: .public)")

        // Load agent prompts from settings
        let agentPrompts = try loadAgentPrompts()

        // Format the context from the graph data
        let formattedContext = formatContext(
            relatedNodes: relatedNodes,
            reasoningPaths: reasoningPaths,
            graphPaths: graphPaths
        )

        // Step 1: Engineer Agent - Synthesize with citations
        logger.info("Running Engineer agent...")
        let engineerPrompt = """
            Question: \(question)

            Initial Analysis:
            \(initialAnswer)

            Knowledge Graph Relationships:
            \(formattedContext)

            Please synthesize this information with proper academic citations.
            """

        let synthesizedAnswer = try await generateWithLLM(
            systemPrompt: agentPrompts.engineerPrompt,
            userPrompt: engineerPrompt
        )
        logger.info("Engineer agent completed")

        // Step 2: Hypothesizer Agent - Generate hypotheses
        logger.info("Running Hypothesizer agent...")
        let hypothesizerPrompt = """
            Original Question: \(question)

            Synthesized Analysis:
            \(synthesizedAnswer)

            Knowledge Graph Context:
            \(formattedContext)

            Based on this analysis, suggest hypotheses, experiments, and follow-up investigations.
            """

        let hypotheses = try await generateWithLLM(
            systemPrompt: agentPrompts.hypothesizerPrompt,
            userPrompt: hypothesizerPrompt
        )
        logger.info("Hypothesizer agent completed")

        return DeepAnalysisResult(
            synthesizedAnswer: synthesizedAnswer,
            hypotheses: hypotheses
        )
    }

    // MARK: - Agent Prompts

    private struct AgentPrompts {
        let engineerPrompt: String
        let hypothesizerPrompt: String
    }

    /// Loads agent prompts from the database, falling back to defaults if not configured.
    private func loadAgentPrompts() throws -> AgentPrompts {
        try database.read { db in
            var engineerPrompt = AppSettings.defaultEngineerAgentPrompt
            var hypothesizerPrompt = AppSettings.defaultHypothesizerAgentPrompt

            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.engineerAgentPrompt)
                .fetchOne(db) {
                engineerPrompt = setting.value
            }

            if let setting = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.hypothesizerAgentPrompt)
                .fetchOne(db) {
                hypothesizerPrompt = setting.value
            }

            return AgentPrompts(
                engineerPrompt: engineerPrompt,
                hypothesizerPrompt: hypothesizerPrompt
            )
        }
    }

    // MARK: - Private Helpers

    /// Formats the graph context for LLM consumption.
    private func formatContext(
        relatedNodes: [GraphRAGResponse.RelatedNode],
        reasoningPaths: [GraphRAGResponse.ReasoningPath],
        graphPaths: [GraphRAGResponse.GraphPath]
    ) -> String {
        var parts: [String] = []

        // Related concepts
        if !relatedNodes.isEmpty {
            let nodesList = relatedNodes.prefix(15).map { node in
                "- \(node.label)" + (node.nodeType.map { " (\($0))" } ?? "")
            }.joined(separator: "\n")
            parts.append("## Related Concepts\n\(nodesList)")
        }

        // Reasoning paths (multi-hop connections)
        if !reasoningPaths.isEmpty {
            let pathsList = reasoningPaths.prefix(10).map { path in
                if path.intermediateNodes.isEmpty {
                    return "- \(path.sourceConcept) → \(path.targetConcept)"
                } else {
                    let intermediates = path.intermediateNodes.joined(separator: " → ")
                    return "- \(path.sourceConcept) → \(intermediates) → \(path.targetConcept)"
                }
            }.joined(separator: "\n")
            parts.append("## Multi-Hop Reasoning Paths\n\(pathsList)")
        }

        // Direct relationships from graph
        if !graphPaths.isEmpty {
            let relationsList = graphPaths.prefix(20).map { path in
                path.naturalLanguageSentence
            }.joined(separator: "\n")
            parts.append("## Knowledge Graph Relationships\n\(relationsList)")
        }

        return parts.joined(separator: "\n\n")
    }

    /// Generates a response using the configured LLM provider.
    @MainActor
    private func generateWithLLM(systemPrompt: String, userPrompt: String) async throws -> String {
        let settings = try loadSettings()

        switch settings.provider {
        case "ollama":
            return try await generateWithOllama(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        case "openrouter":
            return try await generateWithOpenRouter(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        default:
            throw DeepAnalysisError.noProviderConfigured
        }
    }

    @MainActor
    private func generateWithOllama(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        let endpoint = settings.ollamaEndpoint ?? "http://localhost:11434"
        let model = settings.ollamaModel ?? "llama3.2:3b"

        guard let host = URL(string: endpoint) else {
            throw DeepAnalysisError.invalidConfiguration("Invalid Ollama endpoint")
        }

        let ollama = OllamaService(host: host, chatModel: model)
        return try await ollama.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt
        )
    }

    @MainActor
    private func generateWithOpenRouter(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
            throw DeepAnalysisError.missingAPIKey
        }

        let model = settings.openRouterModel ?? "meta-llama/llama-4-maverick"
        let openRouter = try OpenRouterService(apiKey: apiKey, model: model)

        return try await openRouter.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            temperature: 0.7
        )
    }

    /// Loads LLM settings from the database.
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

            return settings
        }
    }
}

// MARK: - Errors

enum DeepAnalysisError: Error, LocalizedError {
    case noProviderConfigured
    case missingAPIKey
    case invalidConfiguration(String)
    case analysisFailed(String)

    var errorDescription: String? {
        switch self {
        case .noProviderConfigured:
            return "No LLM provider configured. Configure Ollama or OpenRouter in Settings."
        case .missingAPIKey:
            return "API key is missing for the configured provider."
        case .invalidConfiguration(let message):
            return "Invalid configuration: \(message)"
        case .analysisFailed(let message):
            return "Deep analysis failed: \(message)"
        }
    }
}
