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
    static let defaultLLMProvider = ""  // No provider configured by default
    static let ollamaEndpoint = "ollama_endpoint"
    static let defaultOllamaEndpoint = "http://localhost:11434"
    static let ollamaModel = "ollama_model"
    static let defaultOllamaModel = "llama3.2:3b"
    static let openRouterModel = "openrouter_model"
    static let defaultOpenRouterModel = "meta-llama/llama-4-maverick"

    // Embedding Configuration
    static let embeddingProvider = "embedding_provider"
    static let defaultEmbeddingProvider = "ollama"
    static let embeddingOllamaEndpoint = "embedding_ollama_endpoint"
    static let defaultEmbeddingOllamaEndpoint = "http://localhost:11434"
    static let embeddingOllamaModel = "embedding_ollama_model"
    static let defaultEmbeddingOllamaModel = "nomic-embed-text:v1.5"
    static let embeddingOpenRouterModel = "embedding_openrouter_model"
    static let defaultEmbeddingOpenRouterModel = "openai/text-embedding-3-small"

    // Analysis LLM Configuration (for answers and deep analysis)
    static let analysisLLMProvider = "analysis_llm_provider"
    static let defaultAnalysisLLMProvider = ""  // Empty = Same as Chat LLM
    static let analysisOllamaEndpoint = "analysis_ollama_endpoint"
    static let defaultAnalysisOllamaEndpoint = "http://localhost:11434"
    static let analysisOllamaModel = "analysis_ollama_model"
    static let defaultAnalysisOllamaModel = "llama3.2:3b"
    static let analysisOpenRouterModel = "analysis_openrouter_model"
    static let defaultAnalysisOpenRouterModel = "meta-llama/llama-4-maverick"

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
    static let extractionTemperature = "extraction_temperature"
    static let defaultExtractionTemperature: Float = 0.33
    static let analysisTemperature = "analysis_temperature"
    static let defaultAnalysisTemperature: Float = 0.7
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

    // Deep Analysis Agent Prompts
    static let engineerAgentPrompt = "engineer_agent_prompt"
    static let hypothesizerAgentPrompt = "hypothesizer_agent_prompt"

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
       - Vague references like "the company", "the product", "it", "they", "these", and etc.
       - Generic terms like "technology", "solution", "platform" without specifics
       - References to generic "news article", "post"
       - Opinion statements or speculation
       - Author names or journalist bylines as entities
       - Never make URLs an entity or a relationship

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
        {"source": ["Vision Pro", "iPad Pro"], "relation": "features", "target": ["M2 chip", "R1 processor"]},
        {"source": ["Microsoft", "Oracle"], "relation": "partners with", "target": ["OpenAI"]},
        {"source": ["Tesla"], "relation": "reduces price of", "target": ["Model Y", "Model 3"]},
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

    // MARK: - Deep Analysis Agent Prompts

    /// Default prompt for the Engineer agent - synthesizes with academic citations.
    static let defaultEngineerAgentPrompt = """
    You are a research engineer with scientific backgrounds. Your task is to synthesize \
    information from a knowledge graph into a well-structured answer.

    Rules:
    1. Use academic citation style: '<statement> [1]' where [1] references your sources
    2. Include a References section at the end with: [1] <REFERENCE>: <reasoning>
    3. Only cite information from the provided knowledge graph relationships
    4. Mark hypothetical ideas clearly as "hypothetically" or "potentially"
    5. Do not fabricate references - only use what's provided
    6. Be concise but thorough
    7. Focus on factual connections found in the graph

    Format your response as:
    ANSWER:
    [Your synthesized answer with citations]

    REFERENCES:
    [1] <reference title>: <why this supports the claim>
    [2] ...
    """

    /// Default prompt for the Hypothesizer agent - generates hypotheses.
    static let defaultHypothesizerAgentPrompt = """
    You are a creative hypothesizer and research strategist. Based on the synthesized \
    analysis and knowledge graph connections, your task is to suggest:

    1. **Potential Experiments**: Investigations that could reveal new insights
    2. **Hidden Connections**: Patterns or relationships not explicitly stated
    3. **Follow-up Questions**: Questions worth exploring further
    4. **Novel Applications**: Practical applications of the discovered knowledge

    Rules:
    - Be creative but grounded in the provided information
    - Each suggestion should be actionable and specific
    - Explain the reasoning behind each hypothesis
    - Prioritize suggestions by potential impact

    Format your response as bullet points under each category.
    """
}
