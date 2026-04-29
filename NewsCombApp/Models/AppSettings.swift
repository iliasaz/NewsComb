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
    static let defaultEmbeddingProvider = "nomic"
    static let embeddingOpenRouterModel = "embedding_openrouter_model"
    static let defaultEmbeddingOpenRouterModel = "openai/text-embedding-3-large"
    static let embeddingDimension = "embedding_dimension"
    /// Maximum embedding dimension: (8192 - RelationFamily.count) / 3 ≈ 2726.
    /// Event vectors concatenate 3× the embedding + a one-hot, and sqlite-vec caps at 8192.
    static let maxEmbeddingDimension = 2560  // largest multiple of 256 that fits
    /// Default dimension matches the on-device Nomic Embed Text v1.5 model (768-d).
    static let defaultEmbeddingDimension = 768
    /// Tracks the dimension the vec0 virtual tables were created with.
    /// Used to detect when tables need to be recreated after a dimension change.
    static let activeEmbeddingDimension = "active_embedding_dimension"

    /// Returns the effective embedding dimension for the currently active provider.
    ///
    /// Nomic Embed Text v1.5 always produces 768-d vectors regardless of the
    /// `embedding_dimension` setting (which is only meaningful for OpenRouter).
    /// This helper ensures vec0 tables are created with the correct size.
    static func effectiveEmbeddingDimension(_ db: GRDB.Database) throws -> Int {
        let provider: String
        if let setting = try AppSettings
            .filter(Columns.key == embeddingProvider)
            .fetchOne(db) {
            // Migrate legacy "ollama" provider to "nomic"
            provider = setting.value == "ollama" ? "nomic" : setting.value
        } else {
            provider = defaultEmbeddingProvider
        }

        if provider == "nomic" {
            return NomicEmbeddingService.embeddingDimension  // 768
        }

        // OpenRouter: use the user-configured dimension, clamped to the sqlite-vec limit
        let rawDim: Int
        if let setting = try AppSettings
            .filter(Columns.key == embeddingDimension)
            .fetchOne(db),
           let value = Int(setting.value) {
            rawDim = value
        } else {
            rawDim = defaultEmbeddingDimension
        }
        return min(rawDim, maxEmbeddingDimension)
    }

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

    // Algorithm Parameters - Dimensionality Reduction (PCA + UMAP)
    static let pcaIntermediateDimension = "pca_intermediate_dimension"
    static let defaultPCAIntermediateDimension = 50
    static let umapTargetDimension = "umap_target_dimension"
    static let defaultUMAPTargetDimension = 25
    static let umapNNeighbors = "umap_n_neighbors"
    static let defaultUMAPNNeighbors = 15

    // Algorithm Parameters - HDBSCAN
    static let hdbscanMinClusterSize = "hdbscan_min_cluster_size"
    static let defaultHDBSCANMinClusterSize = 0  // 0 = auto (sqrt-scaled by HDBSCANService.Parameters.validated)
    static let hdbscanMinSamples = "hdbscan_min_samples"
    static let defaultHDBSCANMinSamples = 10
    static let clusterMergeThreshold = "cluster_merge_threshold"
    static let defaultClusterMergeThreshold: Float = 0.85
    static let noisePoolIQRMultiplier = "noise_pool_iqr_multiplier"
    /// Multiplier for the IQR rule used to flag mega-clusters as noise pools (Q3 + k * IQR on log(size)).
    static let defaultNoisePoolIQRMultiplier: Float = 1.5

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

    // Hypergraph Distillation Toggle
    static let distillationEnabled = "distillation_enabled"
    static let defaultDistillationEnabled = false

    // Theme Clustering Prompts
    static let clusterLabelingSystemPrompt = "cluster_labeling_system_prompt"

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

    /// Default cluster labeling prompt — produces a title + paragraph summary for each story theme cluster.
    static let defaultClusterLabelingPrompt = """
    You write concise, fact-dense summaries of news themes. You receive data \
    extracted from multiple news articles that were automatically grouped together. \
    Your job is to describe what is actually happening — who did what, to whom, \
    and what was announced, decided, or discovered.

    You will receive:
    - Key entities (people, companies, products)
    - Types of relationships between them
    - Representative events in Subject-Verb-Object form, with source context \
    from the original article text when available
    - Source article headlines and publisher descriptions

    Writing rules:
    - Title: a specific, factual headline (under 10 words). Name the main actor \
    or subject if one dominates. Do NOT start with a gerund.
    - Summary: 2-5 sentences packed with specifics — names, products, numbers, \
    actions. Lead with the most concrete fact, not a meta-description.
    - NEVER start with "This topic", "This theme", "This cluster", or any \
    third-person reference to the grouping itself. Jump straight into the facts.
    - Name the actors and their actions. "AWS launched SageMaker Inference for \
    custom Nova models" is good. "New infrastructure for deploying AI" is bad.
    - If the grouped items share a clear thread, describe it. If they are loosely \
    related or span several sub-topics, briefly list the key items rather than \
    forcing a single narrative. Honesty about breadth beats false coherence.
    - Only state facts present in the provided data.

    Output EXACTLY this JSON: {"title": "...", "summary": "..."}
    """

    // MARK: - On-Device (Foundation Models) Settings
    static let onDeviceChunkSize = "on_device_chunk_size"
    static let defaultOnDeviceChunkSize = 600
    static let onDeviceExtractionPrompt = "on_device_extraction_prompt"
    static let defaultOnDeviceExtractionPrompt = """
        Extract entity relationships as Subject-Verb-Object triples from the text. \
        Use full entity names, never pronouns. Focus on companies, products, people, \
        and their actions.
        """

    // MARK: - Classification Provider
    static let simClassificationProvider = "sim_classification_provider"
    static let defaultSimClassificationProvider = "openrouter"

    // MARK: - Entity Classification
    static let simClassificationModel = "sim_classification_model"
    static let defaultSimClassificationModel = "openai/gpt-4.1-nano"
    static let simClassificationPrompt = "sim_classification_prompt"
    static let simClassificationBatchSize = "sim_classification_batch_size"
    static let defaultSimClassificationBatchSize = 20
    static let simClassificationThreads = "sim_classification_threads"
    static let defaultSimClassificationThreads = 8
    static let defaultSimClassificationPrompt = """
        You are classifying entities for a social media simulation. Each entity is \
        either an "actor" (someone who could act on a social platform) or a "non-actor" \
        (a thing, concept, or event that provides context but does not act).

        Actor types: person, organization, company, government_entity, institution.
        Non-actor type: non-actor (products, concepts, events, locations, etc.)

        IMPORTANT: An actor must be a specific, concrete entity — e.g. "Apple", \
        "John Smith", "NIH", "European Commission". Generic or categorical terms like \
        "developers", "IT companies", "government agency", or "scientists" are non-actors.

        For each entity, consider its name and relationship context. Respond with a \
        JSON array where each element has "node_id" and "type" fields.

        Example response:
        [{"node_id": 1, "type": "person"}, {"node_id": 2, "type": "non-actor"}]
        """

    // MARK: - Social Simulation Configuration
    static let simPythonPath = "sim_python_path"
    static let defaultSimPythonPath = "/usr/bin/python3"
    static let simWorkingDirectory = "sim_working_directory"
    static let defaultSimWorkingDirectory = ""  // empty means use default app support path
    static let simDefaultMaxRounds = "sim_default_max_rounds"
    static let defaultSimDefaultMaxRounds = 72
    static let simMinutesPerRound = "sim_minutes_per_round"
    static let defaultSimMinutesPerRound: Double = 60.0
    static let simAgentsPerHourMin = "sim_agents_per_hour_min"
    static let defaultSimAgentsPerHourMin = 3
    static let simAgentsPerHourMax = "sim_agents_per_hour_max"
    static let defaultSimAgentsPerHourMax = 10
    static let simSemaphoreLimit = "sim_semaphore_limit"
    static let defaultSimSemaphoreLimit = 128
    static let simDetectedPythonPath = "sim_detected_python_path"
    static let simOasisVersion = "sim_oasis_version"
    static let simProfilePrompt = "sim_profile_prompt"
    static let defaultSimProfilePrompt = """
    You are a persona designer for a social media simulation. Given information about \
    a real-world entity from a news knowledge graph, create a realistic social media \
    persona for that entity. Respond ONLY with valid JSON matching the schema below.

    The JSON must have these fields:
    {
      "age": <integer or null if organization>,
      "profession": "<role or sector>",
      "interests": ["<topic1>", "<topic2>", ...],
      "mbti": "<4-letter type or null>",
      "sentimentBias": <float -1.0 to 1.0, based on the entity's typical stance>,
      "stance": "<brief description of known positions or outlook>",
      "influenceWeight": <float 0.0 to 1.0, based on prominence>
    }
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
