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

    // Feed Configuration
    static let articleAgeLimitDays = "article_age_limit_days"
    static let defaultArticleAgeLimitDays = 7

    // Graph Visualization
    static let graphNodeColor = "graph_node_color"
    static let defaultGraphNodeColor = "32D74B"  // Flora green

    // Algorithm Parameters - Text Chunking
    static let chunkSize = "chunk_size"
    static let defaultChunkSize = 800  // characters

    // Algorithm Parameters - Node Merging
    static let similarityThreshold = "similarity_threshold"
    static let defaultSimilarityThreshold: Float = 0.9  // 90% similarity

    // Algorithm Parameters - LLM
    static let llmTemperature = "llm_temperature"
    static let defaultLLMTemperature: Float = 0.7
    static let llmMaxTokens = "llm_max_tokens"
    static let defaultLLMMaxTokens = 2048

    // Algorithm Parameters - RAG Query
    static let ragMaxNodes = "rag_max_nodes"
    static let defaultRAGMaxNodes = 10
    static let ragMaxChunks = "rag_max_chunks"
    static let defaultRAGMaxChunks = 5
}
