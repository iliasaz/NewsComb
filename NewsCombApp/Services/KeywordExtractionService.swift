import Foundation
import GRDB
import HyperGraphReasoning
import OSLog

/// Extracts search keywords from a natural-language question using the configured LLM provider.
///
/// Used by both `GraphRAGService` (in-app "Ask Your Knowledge Graph") and
/// `MCPQueryKnowledgeGraphTool` (MCP server RAG pipeline). Loads LLM settings
/// from the database and dispatches to Ollama, OpenRouter, or Apple Foundation Model.
/// Falls back to rule-based stopword filtering if no LLM is configured or available.
enum KeywordExtractionService {

    private static let logger = Logger(subsystem: "com.newscomb.app", category: "KeywordExtraction")

    // MARK: - Public API

    /// Extracts keywords from a question using the configured LLM provider.
    /// Falls back to rule-based extraction if the LLM is unavailable or fails.
    static func extractKeywords(
        from question: String,
        database: any MCPDatabaseReader = Database.shared
    ) async -> [String] {
        do {
            let settings = try loadSettings(database: database)
            return try await extractWithLLM(question: question, settings: settings)
        } catch {
            logger.info("LLM keyword extraction failed, using fallback: \(error.localizedDescription, privacy: .public)")
            return extractKeywordsFallback(from: question)
        }
    }

    // MARK: - System Prompt

    static let keywordExtractionPrompt = """
        You are a strict keyword extractor for a knowledge graph search.

        Rules:
        - Output EXACTLY one JSON object: {"keywords": [<strings>]} with no extra text.
        - Extract the key entities, concepts, and domain-specific terms from the question.
        - Include proper nouns (people, organizations, places), technical terms, and important concepts.
        - Avoid generic terms like company, people, developer - unless they are an essential part of the question.
        - Never include verbs, stopwords, or question words (who, what, how, etc.).
        - Lowercase all keywords unless they are acronyms or proper nouns.
        - Return 2-5 keywords maximum.
        - No explanations, just the JSON.

        Example:
        Question: "How can hydrogel mechanistically relate to PCL?"
        {"keywords": ["hydrogel", "PCL"]}

        Example:
        Question: "What companies are partnering with Google Cloud?"
        {"keywords": ["Google Cloud", "partners"]}
        """

    // MARK: - LLM Dispatch

    private static func extractWithLLM(question: String, settings: LLMSettings) async throws -> [String] {
        let userPrompt = "Question: \"\(question)\""

        let response: String
        switch settings.provider {
        case "ollama":
            response = try await generateWithOllama(
                systemPrompt: keywordExtractionPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        case "openrouter":
            response = try await generateWithOpenRouter(
                systemPrompt: keywordExtractionPrompt,
                userPrompt: userPrompt,
                settings: settings
            )
        case "on_device":
            response = try await generateWithFoundationModel(
                systemPrompt: keywordExtractionPrompt,
                userPrompt: userPrompt
            )
        default:
            return extractKeywordsFallback(from: question)
        }

        return parseKeywordsFromJSON(response) ?? extractKeywordsFallback(from: question)
    }

    // MARK: - LLM Providers

    @MainActor
    private static func generateWithOllama(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        let endpoint = settings.ollamaEndpoint ?? AppSettings.defaultOllamaEndpoint
        let model = settings.ollamaModel ?? AppSettings.defaultOllamaModel

        guard let host = URL(string: endpoint) else {
            throw KeywordExtractionError.invalidConfiguration("Invalid Ollama endpoint")
        }

        let ollama = OllamaService(host: host, chatModel: model)
        return try await ollama.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            temperature: settings.extractionTemperature
        )
    }

    @MainActor
    private static func generateWithOpenRouter(
        systemPrompt: String,
        userPrompt: String,
        settings: LLMSettings
    ) async throws -> String {
        guard let apiKey = settings.openRouterKey, !apiKey.isEmpty else {
            throw KeywordExtractionError.missingAPIKey
        }

        let model = settings.openRouterModel ?? AppSettings.defaultOpenRouterModel
        let openRouter = try OpenRouterService(apiKey: apiKey, model: model)

        return try await openRouter.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            temperature: settings.extractionTemperature
        )
    }

    private static func generateWithFoundationModel(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> String {
        guard case .available = FoundationModelAvailability.check() else {
            throw KeywordExtractionError.invalidConfiguration(
                "On-device Foundation Model is not available."
            )
        }

        let service = FoundationModelService()
        return try await service.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: nil,
            temperature: nil
        )
    }

    // MARK: - JSON Parsing

    /// Parses keywords from a JSON response like {"keywords": ["a", "b"]}.
    static func parseKeywordsFromJSON(_ response: String) -> [String]? {
        let cleaned = response
            .replacing("```json", with: "")
            .replacing("```", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard let data = cleaned.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let keywords = json["keywords"] as? [String],
              !keywords.isEmpty else {
            return nil
        }

        return keywords
    }

    // MARK: - Fallback Extraction

    /// Rule-based keyword extraction using stopword filtering.
    /// Used when no LLM provider is configured or when LLM extraction fails.
    static func extractKeywordsFallback(from question: String) -> [String] {
        let stopwords: Set<String> = [
            "a", "an", "the", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "must", "shall", "can", "need", "dare",
            "to", "of", "in", "for", "on", "with", "at", "by", "from", "as",
            "into", "through", "during", "before", "after", "above", "below",
            "between", "under", "again", "further", "then", "once", "here",
            "there", "when", "where", "why", "how", "all", "each", "few",
            "more", "most", "other", "some", "such", "no", "nor", "not",
            "only", "own", "same", "so", "than", "too", "very", "just",
            "and", "but", "if", "or", "because", "until", "while", "what",
            "which", "who", "whom", "this", "that", "these", "those", "am",
            "about", "it", "its", "they", "their", "them", "we", "us", "our",
            "you", "your", "he", "she", "him", "her", "his", "i", "me", "my",
            "tell", "explain", "describe", "show", "find", "get", "give",
            "know", "think", "say", "make", "go", "take", "come", "see",
            "look", "want", "use", "work", "call", "try", "ask", "let",
            "help", "talk", "turn", "start", "run", "move", "play",
            "related", "relationship", "connect", "connection",
        ]

        let words = question
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 2 && !stopwords.contains($0) }

        var seen: Set<String> = []
        var unique: [String] = []
        for word in words {
            if seen.insert(word).inserted { unique.append(word) }
            if unique.count >= 5 { break }
        }
        return unique
    }

    // MARK: - Settings

    private static func loadSettings(database: any MCPDatabaseReader) throws -> LLMSettings {
        try database.read { db in
            var settings = LLMSettings()

            let rows = try AppSettings.fetchAll(db)
            let dict = Dictionary(uniqueKeysWithValues: rows.map { ($0.key, $0.value) })

            settings.provider = dict[AppSettings.llmProvider] ?? ""
            settings.ollamaEndpoint = dict[AppSettings.ollamaEndpoint]
            settings.ollamaModel = dict[AppSettings.ollamaModel]
            settings.openRouterKey = dict[AppSettings.openRouterKey]
            settings.openRouterModel = dict[AppSettings.openRouterModel]
            settings.embeddingProvider = dict[AppSettings.embeddingProvider] ?? "nomic"

            if let temp = dict[AppSettings.extractionTemperature].flatMap(Double.init) {
                settings.extractionTemperature = temp
            }

            return settings
        }
    }

    // MARK: - Error

    enum KeywordExtractionError: Error {
        case invalidConfiguration(String)
        case missingAPIKey
    }
}
