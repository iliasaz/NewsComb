import Foundation
import Observation
import GRDB

/// LLM provider options for knowledge extraction.
enum LLMProviderOption: String, CaseIterable, Identifiable {
    case none = ""
    case ollama = "ollama"
    case openrouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .ollama: return "Ollama (Local)"
        case .openrouter: return "OpenRouter (Cloud)"
        }
    }
}

/// Embedding provider options.
enum EmbeddingProviderOption: String, CaseIterable, Identifiable {
    case ollama = "ollama"
    case openrouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ollama: return "Ollama (Local)"
        case .openrouter: return "OpenRouter (Cloud)"
        }
    }
}

/// Analysis LLM provider options (for answers and deep analysis).
enum AnalysisLLMProviderOption: String, CaseIterable, Identifiable {
    case sameAsChat = ""
    case ollama = "ollama"
    case openrouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .sameAsChat: return "Same as Chat LLM"
        case .ollama: return "Ollama (Local)"
        case .openrouter: return "OpenRouter (Cloud)"
        }
    }
}

@MainActor
@Observable
class SettingsViewModel {
    var rssSources: [RSSSource] = []
    var newSourceURL: String = ""
    var openRouterKey: String = ""
    var errorMessage: String?

    // LLM Configuration
    var llmProvider: LLMProviderOption = .none
    var ollamaEndpoint: String = AppSettings.defaultOllamaEndpoint
    var ollamaModel: String = AppSettings.defaultOllamaModel
    var openRouterModel: String = AppSettings.defaultOpenRouterModel

    // Embedding Configuration
    var embeddingProvider: EmbeddingProviderOption = .ollama
    var embeddingOllamaEndpoint: String = AppSettings.defaultEmbeddingOllamaEndpoint
    var embeddingOllamaModel: String = AppSettings.defaultEmbeddingOllamaModel
    var embeddingOpenRouterModel: String = AppSettings.defaultEmbeddingOpenRouterModel

    // Analysis LLM Configuration (for answers and deep analysis)
    var analysisLLMProvider: AnalysisLLMProviderOption = .sameAsChat
    var analysisOllamaEndpoint: String = AppSettings.defaultAnalysisOllamaEndpoint
    var analysisOllamaModel: String = AppSettings.defaultAnalysisOllamaModel
    var analysisOpenRouterModel: String = AppSettings.defaultAnalysisOpenRouterModel

    // Feed Configuration
    var articleAgeLimitDays: Int = AppSettings.defaultArticleAgeLimitDays

    // Algorithm Parameters
    var chunkSize: Int = AppSettings.defaultChunkSize
    var similarityThreshold: Float = AppSettings.defaultSimilarityThreshold
    var llmTemperature: Float = AppSettings.defaultLLMTemperature
    var llmMaxTokens: Int = AppSettings.defaultLLMMaxTokens
    var ragMaxNodes: Int = AppSettings.defaultRAGMaxNodes
    var ragMaxChunks: Int = AppSettings.defaultRAGMaxChunks
    var maxPathDepth: Int = AppSettings.defaultMaxPathDepth
    var maxConcurrentProcessing: Int = AppSettings.defaultMaxConcurrentProcessing

    // Extraction Prompts
    var extractionSystemPrompt: String = AppSettings.defaultExtractionPrompt
    var distillationSystemPrompt: String = AppSettings.defaultDistillationPrompt

    // Deep Analysis Agent Prompts
    var engineerAgentPrompt: String = AppSettings.defaultEngineerAgentPrompt
    var hypothesizerAgentPrompt: String = AppSettings.defaultHypothesizerAgentPrompt

    private let database = Database.shared

    func loadData() {
        loadRSSSources()
        loadAPIKeys()
    }

    private func loadRSSSources() {
        do {
            rssSources = try database.read { db in
                try RSSSource.fetchAll(db)
            }
        } catch {
            errorMessage = "Failed to load RSS sources: \(error.localizedDescription)"
        }
    }

    private func loadAPIKeys() {
        do {
            try database.read { db in
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterKey).fetchOne(db) {
                    openRouterKey = setting.value
                }

                // Load LLM provider settings
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.llmProvider).fetchOne(db) {
                    llmProvider = LLMProviderOption(rawValue: setting.value) ?? .none
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.ollamaEndpoint).fetchOne(db) {
                    ollamaEndpoint = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.ollamaModel).fetchOne(db) {
                    ollamaModel = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterModel).fetchOne(db) {
                    openRouterModel = setting.value
                }

                // Load embedding settings
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.embeddingProvider).fetchOne(db) {
                    embeddingProvider = EmbeddingProviderOption(rawValue: setting.value) ?? .ollama
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.embeddingOllamaEndpoint).fetchOne(db) {
                    embeddingOllamaEndpoint = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.embeddingOllamaModel).fetchOne(db) {
                    embeddingOllamaModel = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.embeddingOpenRouterModel).fetchOne(db) {
                    embeddingOpenRouterModel = setting.value
                }

                // Load analysis LLM settings
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisLLMProvider).fetchOne(db) {
                    analysisLLMProvider = AnalysisLLMProviderOption(rawValue: setting.value) ?? .sameAsChat
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisOllamaEndpoint).fetchOne(db) {
                    analysisOllamaEndpoint = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisOllamaModel).fetchOne(db) {
                    analysisOllamaModel = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisOpenRouterModel).fetchOne(db) {
                    analysisOpenRouterModel = setting.value
                }

                // Load feed configuration
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.articleAgeLimitDays).fetchOne(db),
                   let days = Int(setting.value) {
                    articleAgeLimitDays = days
                }

                // Load algorithm parameters
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.chunkSize).fetchOne(db),
                   let value = Int(setting.value) {
                    chunkSize = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.similarityThreshold).fetchOne(db),
                   let value = Float(setting.value) {
                    similarityThreshold = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.llmTemperature).fetchOne(db),
                   let value = Float(setting.value) {
                    llmTemperature = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.llmMaxTokens).fetchOne(db),
                   let value = Int(setting.value) {
                    llmMaxTokens = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.ragMaxNodes).fetchOne(db),
                   let value = Int(setting.value) {
                    ragMaxNodes = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.ragMaxChunks).fetchOne(db),
                   let value = Int(setting.value) {
                    ragMaxChunks = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.maxPathDepth).fetchOne(db),
                   let value = Int(setting.value) {
                    maxPathDepth = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.maxConcurrentProcessing).fetchOne(db),
                   let value = Int(setting.value) {
                    maxConcurrentProcessing = value
                }

                // Load extraction prompts
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.extractionSystemPrompt).fetchOne(db) {
                    extractionSystemPrompt = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.distillationSystemPrompt).fetchOne(db) {
                    distillationSystemPrompt = setting.value
                }

                // Load deep analysis agent prompts
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.engineerAgentPrompt).fetchOne(db) {
                    engineerAgentPrompt = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.hypothesizerAgentPrompt).fetchOne(db) {
                    hypothesizerAgentPrompt = setting.value
                }
            }
        } catch {
            errorMessage = "Failed to load settings: \(error.localizedDescription)"
        }
    }

    func addSource() {
        let trimmed = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        addSourceURL(trimmed)
        newSourceURL = ""
    }

    func pasteMultipleSources(_ text: String) {
        let urls = text.components(separatedBy: CharacterSet.newlines)
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("http") }

        for url in urls {
            addSourceURL(url)
        }
    }

    private func addSourceURL(_ url: String) {
        let normalizedURL = normalizeURL(url)

        // Check if URL already exists (normalized comparison)
        let existingURLs = rssSources.map { normalizeURL($0.url) }
        if existingURLs.contains(normalizedURL) {
            errorMessage = "This feed URL already exists in your sources."
            return
        }

        do {
            _ = try database.write { db in
                try RSSSource(url: normalizedURL).insert(db, onConflict: .ignore)
            }
            loadRSSSources()
        } catch {
            errorMessage = "Failed to add source: \(error.localizedDescription)"
        }
    }

    /// Normalize URL for consistent comparison
    /// - Removes trailing slashes
    /// - Lowercases the scheme and host
    /// - Removes default ports (80 for http, 443 for https)
    private func normalizeURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Lowercase scheme and host
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // Remove default ports
        if let port = components.port {
            if (components.scheme == "http" && port == 80) ||
               (components.scheme == "https" && port == 443) {
                components.port = nil
            }
        }

        // Remove trailing slash from path
        if components.path.hasSuffix("/") && components.path.count > 1 {
            components.path = String(components.path.dropLast())
        }

        return components.string ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteSource(_ source: RSSSource) {
        do {
            _ = try database.write { db in
                try source.delete(db)
            }
            loadRSSSources()
        } catch {
            errorMessage = "Failed to delete source: \(error.localizedDescription)"
        }
    }

    func deleteSource(at offsets: IndexSet) {
        for index in offsets {
            deleteSource(rssSources[index])
        }
    }

    func saveOpenRouterKey() {
        saveAPIKey(key: AppSettings.openRouterKey, value: openRouterKey)
    }

    func saveLLMProvider() {
        saveAPIKey(key: AppSettings.llmProvider, value: llmProvider.rawValue)
    }

    func saveOllamaEndpoint() {
        saveAPIKey(key: AppSettings.ollamaEndpoint, value: ollamaEndpoint)
    }

    func saveOllamaModel() {
        saveAPIKey(key: AppSettings.ollamaModel, value: ollamaModel)
    }

    func saveOpenRouterModel() {
        saveAPIKey(key: AppSettings.openRouterModel, value: openRouterModel)
    }

    func saveEmbeddingProvider() {
        saveAPIKey(key: AppSettings.embeddingProvider, value: embeddingProvider.rawValue)
    }

    func saveEmbeddingOllamaEndpoint() {
        saveAPIKey(key: AppSettings.embeddingOllamaEndpoint, value: embeddingOllamaEndpoint)
    }

    func saveEmbeddingOllamaModel() {
        saveAPIKey(key: AppSettings.embeddingOllamaModel, value: embeddingOllamaModel)
    }

    func saveEmbeddingOpenRouterModel() {
        saveAPIKey(key: AppSettings.embeddingOpenRouterModel, value: embeddingOpenRouterModel)
    }

    // MARK: - Analysis LLM Save Methods

    func saveAnalysisLLMProvider() {
        saveAPIKey(key: AppSettings.analysisLLMProvider, value: analysisLLMProvider.rawValue)
    }

    func saveAnalysisOllamaEndpoint() {
        saveAPIKey(key: AppSettings.analysisOllamaEndpoint, value: analysisOllamaEndpoint)
    }

    func saveAnalysisOllamaModel() {
        saveAPIKey(key: AppSettings.analysisOllamaModel, value: analysisOllamaModel)
    }

    func saveAnalysisOpenRouterModel() {
        saveAPIKey(key: AppSettings.analysisOpenRouterModel, value: analysisOpenRouterModel)
    }

    func saveArticleAgeLimitDays() {
        saveAPIKey(key: AppSettings.articleAgeLimitDays, value: String(articleAgeLimitDays))
    }

    // MARK: - Algorithm Parameters Save Methods

    func saveChunkSize() {
        saveAPIKey(key: AppSettings.chunkSize, value: String(chunkSize))
    }

    func saveSimilarityThreshold() {
        saveAPIKey(key: AppSettings.similarityThreshold, value: String(similarityThreshold))
    }

    func saveLLMTemperature() {
        saveAPIKey(key: AppSettings.llmTemperature, value: String(llmTemperature))
    }

    func saveLLMMaxTokens() {
        saveAPIKey(key: AppSettings.llmMaxTokens, value: String(llmMaxTokens))
    }

    func saveRAGMaxNodes() {
        saveAPIKey(key: AppSettings.ragMaxNodes, value: String(ragMaxNodes))
    }

    func saveRAGMaxChunks() {
        saveAPIKey(key: AppSettings.ragMaxChunks, value: String(ragMaxChunks))
    }

    func saveMaxPathDepth() {
        saveAPIKey(key: AppSettings.maxPathDepth, value: String(maxPathDepth))
    }

    func saveMaxConcurrentProcessing() {
        saveAPIKey(key: AppSettings.maxConcurrentProcessing, value: String(maxConcurrentProcessing))
    }

    // MARK: - Extraction Prompts Save Methods

    func saveExtractionSystemPrompt() {
        saveAPIKey(key: AppSettings.extractionSystemPrompt, value: extractionSystemPrompt)
    }

    func saveDistillationSystemPrompt() {
        saveAPIKey(key: AppSettings.distillationSystemPrompt, value: distillationSystemPrompt)
    }

    func resetExtractionPromptToDefault() {
        extractionSystemPrompt = AppSettings.defaultExtractionPrompt
        saveExtractionSystemPrompt()
    }

    func resetDistillationPromptToDefault() {
        distillationSystemPrompt = AppSettings.defaultDistillationPrompt
        saveDistillationSystemPrompt()
    }

    // MARK: - Deep Analysis Agent Prompts Save Methods

    func saveEngineerAgentPrompt() {
        saveAPIKey(key: AppSettings.engineerAgentPrompt, value: engineerAgentPrompt)
    }

    func saveHypothesizerAgentPrompt() {
        saveAPIKey(key: AppSettings.hypothesizerAgentPrompt, value: hypothesizerAgentPrompt)
    }

    func resetEngineerAgentPromptToDefault() {
        engineerAgentPrompt = AppSettings.defaultEngineerAgentPrompt
        saveEngineerAgentPrompt()
    }

    func resetHypothesizerAgentPromptToDefault() {
        hypothesizerAgentPrompt = AppSettings.defaultHypothesizerAgentPrompt
        saveHypothesizerAgentPrompt()
    }

    private func saveAPIKey(key: String, value: String) {
        do {
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO app_settings (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value]
                )
            }
        } catch {
            errorMessage = "Failed to save API key: \(error.localizedDescription)"
        }
    }
}
