import Foundation
import GRDB

struct AppSettings: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var key: String
    var value: String

    static let databaseTableName = "app_settings"

    enum Columns: String, ColumnExpression {
        case id, key, value
    }

    init(id: Int64? = nil, key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

extension AppSettings {
    static let openRouterKey = "openrouter_key"

    // LLM Configuration for Knowledge Extraction
    static let llmProvider = "llm_provider"
    static let ollamaEndpoint = "ollama_endpoint"
    static let ollamaModel = "ollama_model"
    static let openRouterModel = "openrouter_model"

    // Embedding Configuration
    static let embeddingProvider = "embedding_provider"
    static let embeddingOllamaEndpoint = "embedding_ollama_endpoint"
    static let embeddingOllamaModel = "embedding_ollama_model"
    static let embeddingOpenRouterModel = "embedding_openrouter_model"
}
