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

    // Algorithm Parameters - Graph Path Finding
    static let maxPathDepth = "max_path_depth"
    static let defaultMaxPathDepth = 4  // Maximum BFS depth (path length = depth + 1)

    // Algorithm Parameters - Concurrent Processing
    static let maxConcurrentProcessing = "max_concurrent_processing"
    static let defaultMaxConcurrentProcessing = 10

    // Hypergraph Extraction Prompts
    static let extractionSystemPrompt = "extraction_system_prompt"
    static let distillationSystemPrompt = "distillation_system_prompt"

    // MARK: - Default Tech News Prompts

    /// Default extraction prompt optimized for tech news articles.
    static let defaultExtractionPrompt = """
    You are a knowledge graph extractor that extracts precise Subject–Verb–Object triples from tech news articles.

    You are provided with a context chunk (delimited by triple backticks: ```).
    Extract factual relationships between entities mentioned in the text.

    Guidelines:
    1) Focus on extracting relationships about:
       - Companies and their actions (launches, acquires, partners with, competes with)
       - Products and technologies (features, capabilities, integrations)
       - People in their professional roles (CEO announces, researcher discovers)
       - Market dynamics (raises funding, IPO, valuation)
       - Technical specifications and comparisons

    2) Entity extraction rules:
       - Use full company names (e.g., "Apple Inc." or "Apple", not just pronouns)
       - Include product names with version/model when mentioned (e.g., "iPhone 15 Pro", "GPT-4")
       - For people, use their full name with title/role when relevant (e.g., "CEO Tim Cook")
       - Preserve technical terms exactly as written

    3) Avoid:
       - Vague references like "the company", "the product", "it", "they"
       - Generic terms like "technology", "solution", "platform" without specifics
       - Opinion statements or speculation
       - Author names or journalist bylines as entities

    4) Relationship types to capture:
       - Actions: "launches", "announces", "releases", "acquires", "invests in"
       - Partnerships: "partners with", "collaborates with", "integrates with"
       - Competition: "competes with", "rivals", "challenges"
       - Features: "supports", "enables", "includes", "offers"
       - Causation: "leads to", "results in", "causes", "enables"

    Output Specification:
    Return a JSON object with a single field 'events' (a list of objects).
    Each object must have:
    - 'source': a list of strings (entities performing the action)
    - 'relation': a string (the verb/relationship)
    - 'target': a list of strings (entities receiving the action)

    Example output:
    {
      "events": [
        {"source": ["Apple"], "relation": "announces", "target": ["Vision Pro headset"]},
        {"source": ["Vision Pro"], "relation": "features", "target": ["M2 chip", "R1 processor"]},
        {"source": ["Microsoft"], "relation": "partners with", "target": ["OpenAI"]},
        {"source": ["Tesla"], "relation": "reduces price of", "target": ["Model Y"]},
        {"source": ["Google DeepMind"], "relation": "releases", "target": ["Gemini AI model"]},
        {"source": ["Gemini"], "relation": "competes with", "target": ["GPT-4", "Claude"]}
      ]
    }
    Return only valid JSON. Extract all factual relationships from the text.
    """

    /// Default distillation prompt optimized for tech news articles.
    static let defaultDistillationPrompt = """
    You are a tech news summarizer. Given a news article chunk (delimited by ```), produce:
    1) A concise headline summarizing the main news
    2) Key facts as bullet points
    3) Companies, products, and people mentioned

    Focus on factual information. Ignore:
    - Author names and bylines
    - Publication metadata
    - Promotional language
    - Speculation or opinion

    Preserve technical terms, product names, and company names exactly as written.
    """
}
