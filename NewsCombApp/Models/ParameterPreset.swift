import Foundation
import GRDB

/// A named bundle of `app_settings` values that can be applied to a workspace
/// in one click. Built-in presets are seeded at workspace creation
/// (`is_builtin = 1`); user-defined presets are created via MCP tools or the
/// Settings UI.
///
/// `settings_json` is a flat JSON object mapping `app_settings.key` → value
/// strings. `[String: String]` is the canonical shape; the storage matches
/// what `app_settings` accepts when applied.
struct ParameterPreset: Identifiable, Equatable, Codable, FetchableRecord, MutablePersistableRecord, Sendable {
    var id: Int64?
    var name: String
    var description: String?
    var settingsJSON: String
    var isBuiltin: Bool
    var createdAt: Double
    var updatedAt: Double

    static let databaseTableName = "parameter_preset"

    enum CodingKeys: String, CodingKey {
        case id, name, description
        case settingsJSON = "settings_json"
        case isBuiltin = "is_builtin"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns: String, ColumnExpression {
        case id
        case name
        case description
        case settingsJson = "settings_json"
        case isBuiltin = "is_builtin"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: Int64? = nil,
        name: String,
        description: String? = nil,
        settingsJSON: String,
        isBuiltin: Bool = false,
        createdAt: Double = Date().timeIntervalSince1970,
        updatedAt: Double = Date().timeIntervalSince1970
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.settingsJSON = settingsJSON
        self.isBuiltin = isBuiltin
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    mutating func didInsert(_ inserted: InsertionSuccess) {
        id = inserted.rowID
    }
}

// MARK: - Built-in preset names

extension ParameterPreset {
    /// Canonical name of the News Intelligence built-in preset.
    static let newsIntelligenceName = "News Intelligence"

    /// Canonical name of the Codebase Intelligence built-in preset.
    static let codebaseIntelligenceName = "Codebase Intelligence"

    /// Description shown in the preset list / MCP `list_parameter_presets`.
    static let newsIntelligenceDescription =
        "Tech-news graph at scale. Tuned for 10K-1M event corpora with many semi-related story clusters."

    /// Description shown in the preset list / MCP `list_parameter_presets`.
    static let codebaseIntelligenceDescription =
        "Code, comments, and tech documentation. Tuned for smaller graphs (<10K events) with finer structural detail. Distillation enabled to clean noise from code blocks before extraction."
}

// MARK: - Codebase prompt constants

extension ParameterPreset {

    /// Extraction system prompt tuned for source code, comments, and
    /// technical documentation. Captures identifier-level facts: types,
    /// methods, schema, pipeline stages, and dependencies.
    static let codebaseExtractionPrompt: String = """
    You are a knowledge graph extractor that extracts precise Subject-Verb-Object \
    triples from technical documentation about a software project, including code, \
    comments, README files, and design documents.

    You are provided with a chunk (delimited by triple backticks: ```). Extract \
    factual structural and behavioral relationships between named entities in the \
    text. Treat code samples as strong signal: identifiers, method calls, schema \
    references, and dependency declarations are exactly the entities and relations \
    to capture.

    Guidelines:
    1) Focus on extracting relationships about:
       - Types and their methods (defines, exposes, conforms to, returns)
       - Files and modules (lives in, imports, declares)
       - Database schema (table A has column B, FK from X to Y, trigger on insert)
       - Pipeline stages (A precedes B, A reads from C, A writes to D, A calls B)
       - Configuration knobs (key K controls behavior B, default is V, read by S)
       - Algorithmic choices (algorithm A operates over data D using parameter P)
       - External dependencies (package P provides T, library L is used by S)

    2) Entity extraction rules:
       - Preserve identifier names exactly: casing, dotted qualifiers (Module.Type), \
    generic parameters, parameter labels.
       - Treat hyphenated names as single tokens (sqlite-vec, X-Workspace, \
    meta-llama-4-maverick) — never split on the hyphen.
       - Disambiguate types by their owning module when relevant \
    (NewsCombApp.Database vs HyperGraphReasoning.Database).
       - For methods, include the owning type (HypergraphService.processArticle).

    3) Avoid:
       - Pronominal references ("the service", "this method", "it", "they").
       - Marketing or hype language.
       - Speculation about future versions.
       - Author voice or rhetorical asides.

    4) Preferred relation verbs:
       - Structural: defines, declares, contains, exposes, conforms to, extends
       - Calls: calls, invokes, queries, reads, writes, instantiates
       - Pipeline: precedes, follows, feeds, consumes, triggers
       - Schema: has column, references, cascades to, indexed by
       - Configuration: controls, defaults to, is read by, is configured via
       - Dependency: depends on, imports, requires

    Output Specification:
    Return a JSON object with a single field 'events' (a list of objects). Each \
    object must have:
    - 'source': a list of strings
    - 'relation': a string
    - 'target': a list of strings

    Example:
    {
      "events": [
        {"source": ["HypergraphService.processArticle"], "relation": "calls", \
    "target": ["DocumentProcessor.processText"]},
        {"source": ["NodeMergingService"], "relation": "rewires", \
    "target": ["hypergraph_incidence"]},
        {"source": ["hdbscan_min_cluster_size"], "relation": "controls", \
    "target": ["HDBSCAN cluster size floor"]}
      ]
    }
    Return only valid JSON.
    """

    /// Distillation system prompt tuned for technical documentation. Used
    /// when `distillation_enabled = true` to pre-process noisy chunks
    /// (long code blocks, boilerplate) into a tighter factual core.
    static let codebaseDistillationPrompt: String = """
    You distill technical documentation chunks (which may include source code, \
    comments, and prose) into their factual structural content. Given a chunk \
    delimited by triple backticks, produce:

    1) A concise topic headline (under 12 words) describing what the chunk is about.

    2) Key facts as bullet points. Prefer facts about:
       - What types, methods, or files are described and what they do
       - What database tables or columns are described and how they relate
       - What pipeline stages are described and in what order they run
       - What configuration knobs are described and what they control
       - What design decisions are described and why

    3) Named entities mentioned, classified as one of:
       Type, Method, File, Module, Database table or column, External package, \
    Algorithm, Concept, Configuration setting.

    When the chunk contains source code: extract identifier-level facts. Strip \
    implementation noise (variable shuffling, error handling boilerplate, comment \
    formatting). Keep the structural signal: type signatures, method calls, \
    schema references, dependency declarations.

    Preserve identifier names exactly. Treat hyphenated names as single tokens.
    """

    /// Cluster labeling prompt tuned for technical documentation. Produces
    /// topic headings suitable for a docs table of contents rather than
    /// news headlines.
    static let codebaseClusterLabelingPrompt: String = """
    You write topic headings and short summaries for clusters of facts extracted \
    from technical documentation about a software project. Each cluster groups \
    facts about a coherent slice of the system — a module, an algorithm, a \
    design decision, a call chain, or a cross-cutting concern.

    You will receive:
    - Key entities (types, methods, files, tables, packages, concepts)
    - Types of relationships between them
    - Representative facts in Subject-Verb-Object form, with source context \
    from the documentation when available
    - Source article titles

    Writing rules:
    - Title: a topic heading suitable for a documentation table of contents \
    (under 10 words). Name the dominant subsystem or concept if one stands out. \
    Do NOT start with a gerund.
    - Summary: 2-4 sentences naming the key types, operations, and design \
    decisions involved. Lead with the most concrete structural fact, not a \
    meta-description.
    - NEVER start with "This topic", "This theme", "This cluster".
    - Prefer facts about how the code works over facts about what it produces \
    for end users.
    - If the cluster spans loosely related sub-topics, list the sub-topics \
    rather than forcing a single narrative.
    - Only state facts present in the provided data.

    Output EXACTLY this JSON: {"title": "...", "summary": "..."}
    """
}

// MARK: - Built-in preset settings

extension ParameterPreset {

    /// Returns the seed `app_settings` dictionary for a built-in preset, or
    /// `nil` for unknown names. Used by `seedDefaultPresets` and by the
    /// `reset_parameter_preset` MCP tool to restore a built-in preset to
    /// its shipped defaults.
    static func builtinSettings(forPresetNamed name: String) -> [String: String]? {
        switch name {
        case newsIntelligenceName:
            return newsIntelligenceSettings
        case codebaseIntelligenceName:
            return codebaseIntelligenceSettings
        default:
            return nil
        }
    }

    /// Settings for the News Intelligence preset. Reuses the existing
    /// `AppSettings.default*` constants so the seeded values track any
    /// future tweaks to the project-wide defaults.
    static var newsIntelligenceSettings: [String: String] {
        [
            AppSettings.extractionSystemPrompt: AppSettings.defaultExtractionPrompt,
            AppSettings.distillationSystemPrompt: AppSettings.defaultDistillationPrompt,
            AppSettings.distillationEnabled: "false",
            AppSettings.clusterLabelingSystemPrompt: AppSettings.defaultClusterLabelingPrompt,
            AppSettings.chunkSize: "800",
            AppSettings.onDeviceChunkSize: "600",
            AppSettings.pcaIntermediateDimension: "50",
            AppSettings.umapTargetDimension: "25",
            AppSettings.umapNNeighbors: "15",
            AppSettings.hdbscanMinClusterSize: "0",
            AppSettings.hdbscanMinSamples: "10",
            AppSettings.clusterMergeThreshold: "0.85",
            AppSettings.noisePoolIQRMultiplier: "1.5",
            AppSettings.extractionTemperature: "0.33"
        ]
    }

    /// Settings for the Codebase Intelligence preset. Distillation is
    /// enabled, chunk sizes are larger, and HDBSCAN floors are higher
    /// because codebase graphs are smaller and topically tighter.
    ///
    /// Note: issue #36 lists `on_device_extraction_prompt` as a key for
    /// this preset but does not supply text for it. We omit it from the
    /// seeded settings so the workspace's current on-device prompt is
    /// preserved when this preset is applied; a future revision can add
    /// a tuned variant.
    static var codebaseIntelligenceSettings: [String: String] {
        [
            AppSettings.extractionSystemPrompt: codebaseExtractionPrompt,
            AppSettings.distillationSystemPrompt: codebaseDistillationPrompt,
            AppSettings.distillationEnabled: "true",
            AppSettings.clusterLabelingSystemPrompt: codebaseClusterLabelingPrompt,
            AppSettings.chunkSize: "1200",
            AppSettings.onDeviceChunkSize: "800",
            AppSettings.pcaIntermediateDimension: "50",
            AppSettings.umapTargetDimension: "15",
            AppSettings.umapNNeighbors: "10",
            AppSettings.hdbscanMinClusterSize: "15",
            AppSettings.hdbscanMinSamples: "5",
            AppSettings.clusterMergeThreshold: "0.85",
            AppSettings.noisePoolIQRMultiplier: "1.5",
            AppSettings.extractionTemperature: "0.2"
        ]
    }
}
