import Foundation
import Observation
import GRDB

/// LLM provider options for knowledge extraction.
enum LLMProviderOption: String, CaseIterable, Identifiable {
    case none = ""
    case ollama = "ollama"
    case openrouter = "openrouter"
    case onDevice = "on_device"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .none: return "None"
        case .ollama: return "Ollama (Local)"
        case .openrouter: return "OpenRouter (Cloud)"
        case .onDevice: return "On-Device (Apple Intelligence)"
        }
    }
}

/// Classification LLM provider options.
enum ClassificationProviderOption: String, CaseIterable, Identifiable {
    case openrouter = "openrouter"
    case onDevice = "on_device"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .openrouter: return "OpenRouter (Cloud)"
        case .onDevice: return "On-Device (Apple Intelligence)"
        }
    }
}

/// Embedding provider options.
enum EmbeddingProviderOption: String, CaseIterable, Identifiable {
    case nomic = "nomic"
    case openrouter = "openrouter"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .nomic: return "Nomic (On-Device)"
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
    /// Set after a successful default-feeds seed; the view shows it as an info alert.
    var seedFeedsResultMessage: String?

    // LLM Configuration
    var llmProvider: LLMProviderOption = .none
    var ollamaEndpoint: String = AppSettings.defaultOllamaEndpoint
    var ollamaModel: String = AppSettings.defaultOllamaModel
    var openRouterModel: String = AppSettings.defaultOpenRouterModel

    // Embedding Configuration
    var embeddingProvider: EmbeddingProviderOption = .nomic
    var embeddingOpenRouterModel: String = AppSettings.defaultEmbeddingOpenRouterModel
    var embeddingDimension: Int = AppSettings.defaultEmbeddingDimension

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
    var pcaIntermediateDimension: Int = AppSettings.defaultPCAIntermediateDimension
    var umapTargetDimension: Int = AppSettings.defaultUMAPTargetDimension
    var umapNNeighbors: Int = AppSettings.defaultUMAPNNeighbors
    var hdbscanMinClusterSize: Int = AppSettings.defaultHDBSCANMinClusterSize
    var hdbscanMinSamples: Int = AppSettings.defaultHDBSCANMinSamples
    var clusterMergeThreshold: Float = AppSettings.defaultClusterMergeThreshold
    var noisePoolIQRMultiplier: Float = AppSettings.defaultNoisePoolIQRMultiplier
    var extractionTemperature: Float = AppSettings.defaultExtractionTemperature
    var analysisTemperature: Float = AppSettings.defaultAnalysisTemperature
    var llmMaxTokens: Int = AppSettings.defaultLLMMaxTokens
    var ragMaxNodes: Int = AppSettings.defaultRAGMaxNodes
    var ragMaxChunks: Int = AppSettings.defaultRAGMaxChunks
    var maxPathDepth: Int = AppSettings.defaultMaxPathDepth
    var maxConcurrentProcessing: Int = AppSettings.defaultMaxConcurrentProcessing

    // Extraction Prompts
    var extractionSystemPrompt: String = AppSettings.defaultExtractionPrompt
    var distillationSystemPrompt: String = AppSettings.defaultDistillationPrompt
    var distillationEnabled: Bool = AppSettings.defaultDistillationEnabled

    // Theme Clustering Prompt
    var clusterLabelingSystemPrompt: String = AppSettings.defaultClusterLabelingPrompt

    // Deep Analysis Agent Prompts
    var engineerAgentPrompt: String = AppSettings.defaultEngineerAgentPrompt
    var hypothesizerAgentPrompt: String = AppSettings.defaultHypothesizerAgentPrompt

    // On-Device (Foundation Models)
    var onDeviceChunkSize: Int = AppSettings.defaultOnDeviceChunkSize
    var onDeviceAvailabilityStatus: String = "Not checked"

    // Entity Classification
    var classificationProvider: ClassificationProviderOption = .openrouter
    var simClassificationModel: String = AppSettings.defaultSimClassificationModel
    var simClassificationBatchSize: Int = AppSettings.defaultSimClassificationBatchSize
    var simClassificationThreads: Int = AppSettings.defaultSimClassificationThreads
    var simClassificationPrompt: String = AppSettings.defaultSimClassificationPrompt

    // Social Simulation
    var simPythonPath: String = AppSettings.defaultSimPythonPath
    var simWorkingDirectory: String = AppSettings.defaultSimWorkingDirectory
    var simDefaultMaxRounds: Int = AppSettings.defaultSimDefaultMaxRounds
    var simMinutesPerRound: Double = AppSettings.defaultSimMinutesPerRound
    var simAgentsPerHourMin: Int = AppSettings.defaultSimAgentsPerHourMin
    var simAgentsPerHourMax: Int = AppSettings.defaultSimAgentsPerHourMax
    var simSemaphoreLimit: Int = AppSettings.defaultSimSemaphoreLimit
    var simProfilePrompt: String = AppSettings.defaultSimProfilePrompt

    // Social Simulation — Environment Status
    private(set) var simPythonDetectedPath: String = ""
    private(set) var simOasisStatusText: String = "Not checked"
    private(set) var simOasisInstalled: Bool = false
    private(set) var isCheckingEnvironment: Bool = false

    /// True when the selected embedding provider's dimension doesn't match
    /// the dimension the vec0 tables were built with, and graph data exists.
    var needsGraphRebuild = false

    private let database = Database.current

    func loadData() {
        loadRSSSources()
        loadAPIKeys()
        checkEmbeddingDimensionMismatch()
        refreshOnDeviceAvailability()

        // Auto-check OASIS environment if not already known
        if simPythonDetectedPath.isEmpty || simPythonDetectedPath == "Not found" {
            Task { await checkOasisEnvironment() }
        }
    }

    /// Refreshes the cached on-device model availability status string.
    func refreshOnDeviceAvailability() {
        onDeviceAvailabilityStatus = FoundationModelAvailability.check().statusDescription
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
                    // Migrate legacy "ollama" provider to "nomic"
                    let raw = setting.value == "ollama" ? "nomic" : setting.value
                    embeddingProvider = EmbeddingProviderOption(rawValue: raw) ?? .nomic
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.embeddingOpenRouterModel).fetchOne(db) {
                    embeddingOpenRouterModel = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.embeddingDimension).fetchOne(db),
                   let value = Int(setting.value) {
                    embeddingDimension = min(value, AppSettings.maxEmbeddingDimension)
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

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.pcaIntermediateDimension).fetchOne(db),
                   let value = Int(setting.value) {
                    pcaIntermediateDimension = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.umapTargetDimension).fetchOne(db),
                   let value = Int(setting.value) {
                    umapTargetDimension = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.umapNNeighbors).fetchOne(db),
                   let value = Int(setting.value) {
                    umapNNeighbors = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.hdbscanMinClusterSize).fetchOne(db),
                   let value = Int(setting.value) {
                    hdbscanMinClusterSize = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.hdbscanMinSamples).fetchOne(db),
                   let value = Int(setting.value) {
                    hdbscanMinSamples = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.clusterMergeThreshold).fetchOne(db),
                   let value = Float(setting.value) {
                    clusterMergeThreshold = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.noisePoolIQRMultiplier).fetchOne(db),
                   let value = Float(setting.value) {
                    noisePoolIQRMultiplier = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.extractionTemperature).fetchOne(db),
                   let value = Float(setting.value) {
                    extractionTemperature = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.analysisTemperature).fetchOne(db),
                   let value = Float(setting.value) {
                    analysisTemperature = value
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

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.distillationEnabled).fetchOne(db),
                   let value = Bool(setting.value) {
                    distillationEnabled = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.clusterLabelingSystemPrompt).fetchOne(db) {
                    clusterLabelingSystemPrompt = setting.value
                }

                // Load deep analysis agent prompts
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.engineerAgentPrompt).fetchOne(db) {
                    engineerAgentPrompt = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.hypothesizerAgentPrompt).fetchOne(db) {
                    hypothesizerAgentPrompt = setting.value
                }

                // Load social simulation settings
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simPythonPath).fetchOne(db) {
                    simPythonPath = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simWorkingDirectory).fetchOne(db) {
                    simWorkingDirectory = setting.value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simDefaultMaxRounds).fetchOne(db),
                   let value = Int(setting.value) {
                    simDefaultMaxRounds = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simMinutesPerRound).fetchOne(db),
                   let value = Double(setting.value) {
                    simMinutesPerRound = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simAgentsPerHourMin).fetchOne(db),
                   let value = Int(setting.value) {
                    simAgentsPerHourMin = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simAgentsPerHourMax).fetchOne(db),
                   let value = Int(setting.value) {
                    simAgentsPerHourMax = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simSemaphoreLimit).fetchOne(db),
                   let value = Int(setting.value) {
                    simSemaphoreLimit = value
                }

                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simProfilePrompt).fetchOne(db) {
                    simProfilePrompt = setting.value
                }

                // Load on-device settings
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.onDeviceChunkSize).fetchOne(db),
                   let v = Int(s.value) {
                    onDeviceChunkSize = v
                }

                // Load classification provider
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationProvider).fetchOne(db) {
                    classificationProvider = ClassificationProviderOption(rawValue: s.value) ?? .openrouter
                }

                // Load entity classification settings
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationModel).fetchOne(db) {
                    simClassificationModel = s.value
                }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationBatchSize).fetchOne(db),
                   let v = Int(s.value) {
                    simClassificationBatchSize = v
                }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationThreads).fetchOne(db),
                   let v = Int(s.value) {
                    simClassificationThreads = v
                }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simClassificationPrompt).fetchOne(db) {
                    simClassificationPrompt = s.value
                }

                // Load persisted environment detection results
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simDetectedPythonPath).fetchOne(db),
                   !setting.value.isEmpty {
                    simPythonDetectedPath = setting.value
                }
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simOasisVersion).fetchOne(db),
                   !setting.value.isEmpty {
                    simOasisStatusText = "Installed (v\(setting.value))"
                    simOasisInstalled = true
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
        guard let sourceId = source.id else { return }
        do {
            try database.write { db in
                // Defer FK checks to transaction commit. Unlike `PRAGMA foreign_keys`,
                // `defer_foreign_keys` CAN be set mid-transaction. This lets us delete
                // in any order as long as all references are resolved by commit time.
                // Needed because existing databases have NO ACTION FKs (SQLite can't
                // alter FK constraints on existing tables).
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

                let feedItemIds = try Int64.fetchAll(db, sql:
                    "SELECT id FROM feed_item WHERE source_id = ?", arguments: [sourceId])

                guard !feedItemIds.isEmpty else {
                    try source.delete(db)
                    return
                }

                let chunkIds = try Int64.fetchAll(db, sql: """
                    SELECT id FROM article_chunk WHERE feed_item_id IN
                    (SELECT id FROM feed_item WHERE source_id = ?)
                    """, arguments: [sourceId])

                let edgeIds = try Int64.fetchAll(db, sql: """
                    SELECT id FROM hypergraph_edge WHERE source_chunk_id IN
                    (SELECT id FROM article_chunk WHERE feed_item_id IN
                     (SELECT id FROM feed_item WHERE source_id = ?))
                    """, arguments: [sourceId])

                // Delete edges and their dependents
                for batch in edgeIds.chunked(into: 500) {
                    let ph = batch.map { _ in "?" }.joined(separator: ",")
                    let args = StatementArguments(batch)
                    try db.execute(sql: "DELETE FROM cluster_exemplars WHERE event_id IN (\(ph))", arguments: args)
                    try db.execute(sql: "DELETE FROM cluster_members WHERE event_id IN (\(ph))", arguments: args)
                    try db.execute(sql: "DELETE FROM event_cluster WHERE event_id IN (\(ph))", arguments: args)
                    try db.execute(sql: "DELETE FROM article_edge_provenance WHERE edge_id IN (\(ph))", arguments: args)
                    try db.execute(sql: "DELETE FROM hypergraph_incidence WHERE edge_id IN (\(ph))", arguments: args)
                    try db.execute(sql: "DELETE FROM hypergraph_edge WHERE id IN (\(ph))", arguments: args)
                }
                // vec0 virtual tables require individual deletes
                for edgeId in edgeIds {
                    try db.execute(sql: "DELETE FROM event_vectors WHERE event_id = ?", arguments: [edgeId])
                }

                // Delete chunks and their dependents
                for batch in chunkIds.chunked(into: 500) {
                    let ph = batch.map { _ in "?" }.joined(separator: ",")
                    let args = StatementArguments(batch)
                    try db.execute(sql: "DELETE FROM chunk_embedding_metadata WHERE chunk_id IN (\(ph))", arguments: args)
                    try db.execute(sql: "DELETE FROM article_chunk WHERE id IN (\(ph))", arguments: args)
                }
                // vec0 virtual tables require individual deletes
                for chunkId in chunkIds {
                    try db.execute(sql: "DELETE FROM chunk_embedding WHERE chunk_id = ?", arguments: [chunkId])
                }

                // Delete feed-item-level dependents
                try db.execute(sql: """
                    DELETE FROM article_edge_provenance WHERE feed_item_id IN
                    (SELECT id FROM feed_item WHERE source_id = ?)
                    """, arguments: [sourceId])
                try db.execute(sql: """
                    DELETE FROM article_hypergraph WHERE feed_item_id IN
                    (SELECT id FROM feed_item WHERE source_id = ?)
                    """, arguments: [sourceId])

                // Delete feed items and the source
                try db.execute(sql: "DELETE FROM feed_item WHERE source_id = ?", arguments: [sourceId])
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
        checkEmbeddingDimensionMismatch()
    }

    func saveEmbeddingOpenRouterModel() {
        saveAPIKey(key: AppSettings.embeddingOpenRouterModel, value: embeddingOpenRouterModel)
    }

    func saveEmbeddingDimension() {
        saveAPIKey(key: AppSettings.embeddingDimension, value: String(embeddingDimension))
        checkEmbeddingDimensionMismatch()
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

    /// Inserts the curated default tech-news RSS feeds into the active workspace.
    /// Idempotent — feeds whose URLs already exist are skipped.
    func seedDefaultFeeds() {
        do {
            let inserted = try Database.current.seedDefaultRSSFeeds()
            loadRSSSources()
            seedFeedsResultMessage = inserted == 0
                ? "All default feeds were already present. No new feeds added."
                : "Added \(inserted) default tech feed\(inserted == 1 ? "" : "s")."
        } catch {
            errorMessage = "Failed to seed default feeds: \(error.localizedDescription)"
        }
    }

    // MARK: - Algorithm Parameters Save Methods

    func saveChunkSize() {
        saveAPIKey(key: AppSettings.chunkSize, value: String(chunkSize))
    }

    func saveSimilarityThreshold() {
        saveAPIKey(key: AppSettings.similarityThreshold, value: String(similarityThreshold))
    }

    func savePCAIntermediateDimension() {
        saveAPIKey(key: AppSettings.pcaIntermediateDimension, value: String(pcaIntermediateDimension))
    }

    func saveUMAPTargetDimension() {
        saveAPIKey(key: AppSettings.umapTargetDimension, value: String(umapTargetDimension))
    }

    func saveUMAPNNeighbors() {
        saveAPIKey(key: AppSettings.umapNNeighbors, value: String(umapNNeighbors))
    }

    func saveHDBSCANMinClusterSize() {
        saveAPIKey(key: AppSettings.hdbscanMinClusterSize, value: String(hdbscanMinClusterSize))
    }

    func saveHDBSCANMinSamples() {
        saveAPIKey(key: AppSettings.hdbscanMinSamples, value: String(hdbscanMinSamples))
    }

    func saveClusterMergeThreshold() {
        saveAPIKey(key: AppSettings.clusterMergeThreshold, value: String(clusterMergeThreshold))
    }

    func saveNoisePoolIQRMultiplier() {
        saveAPIKey(key: AppSettings.noisePoolIQRMultiplier, value: String(noisePoolIQRMultiplier))
    }

    func saveExtractionTemperature() {
        saveAPIKey(key: AppSettings.extractionTemperature, value: String(extractionTemperature))
    }

    func saveAnalysisTemperature() {
        saveAPIKey(key: AppSettings.analysisTemperature, value: String(analysisTemperature))
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

    func saveDistillationEnabled() {
        saveAPIKey(key: AppSettings.distillationEnabled, value: String(distillationEnabled))
    }

    func resetExtractionPromptToDefault() {
        extractionSystemPrompt = AppSettings.defaultExtractionPrompt
        saveExtractionSystemPrompt()
    }

    func resetDistillationPromptToDefault() {
        distillationSystemPrompt = AppSettings.defaultDistillationPrompt
        saveDistillationSystemPrompt()
    }

    // MARK: - Theme Clustering Prompt Save Methods

    func saveClusterLabelingSystemPrompt() {
        saveAPIKey(key: AppSettings.clusterLabelingSystemPrompt, value: clusterLabelingSystemPrompt)
    }

    func resetClusterLabelingPromptToDefault() {
        clusterLabelingSystemPrompt = AppSettings.defaultClusterLabelingPrompt
        saveClusterLabelingSystemPrompt()
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

    // MARK: - Social Simulation Save Methods

    func saveSimPythonPath() { saveAPIKey(key: AppSettings.simPythonPath, value: simPythonPath) }
    func saveSimWorkingDirectory() { saveAPIKey(key: AppSettings.simWorkingDirectory, value: simWorkingDirectory) }
    func saveSimDefaultMaxRounds() { saveAPIKey(key: AppSettings.simDefaultMaxRounds, value: String(simDefaultMaxRounds)) }
    func saveSimMinutesPerRound() { saveAPIKey(key: AppSettings.simMinutesPerRound, value: String(simMinutesPerRound)) }
    func saveSimAgentsPerHourMin() { saveAPIKey(key: AppSettings.simAgentsPerHourMin, value: String(simAgentsPerHourMin)) }
    func saveSimAgentsPerHourMax() { saveAPIKey(key: AppSettings.simAgentsPerHourMax, value: String(simAgentsPerHourMax)) }
    func saveSimSemaphoreLimit() { saveAPIKey(key: AppSettings.simSemaphoreLimit, value: String(simSemaphoreLimit)) }
    func saveSimProfilePrompt() { saveAPIKey(key: AppSettings.simProfilePrompt, value: simProfilePrompt) }

    func resetSimProfilePromptToDefault() {
        simProfilePrompt = AppSettings.defaultSimProfilePrompt
        saveSimProfilePrompt()
    }

    // MARK: - On-Device Save Methods

    func saveOnDeviceChunkSize() { saveAPIKey(key: AppSettings.onDeviceChunkSize, value: String(onDeviceChunkSize)) }

    // MARK: - Entity Classification Save Methods

    func saveClassificationProvider() { saveAPIKey(key: AppSettings.simClassificationProvider, value: classificationProvider.rawValue) }
    func saveSimClassificationModel() { saveAPIKey(key: AppSettings.simClassificationModel, value: simClassificationModel) }
    func saveSimClassificationBatchSize() { saveAPIKey(key: AppSettings.simClassificationBatchSize, value: String(simClassificationBatchSize)) }
    func saveSimClassificationThreads() { saveAPIKey(key: AppSettings.simClassificationThreads, value: String(simClassificationThreads)) }
    func saveSimClassificationPrompt() { saveAPIKey(key: AppSettings.simClassificationPrompt, value: simClassificationPrompt) }

    func resetSimClassificationPromptToDefault() {
        simClassificationPrompt = AppSettings.defaultSimClassificationPrompt
        saveSimClassificationPrompt()
    }

    /// Auto-detects Python and checks OASIS installation, persisting results.
    func checkOasisEnvironment() async {
        isCheckingEnvironment = true
        let envService = OasisEnvironmentService()

        if let path = await envService.detectPythonPath() {
            simPythonDetectedPath = path
            simPythonPath = path
            saveSimPythonPath()
            saveAPIKey(key: AppSettings.simDetectedPythonPath, value: path)

            let status = await envService.checkOasisInstalled(pythonPath: path)
            switch status {
            case .installed(let version):
                simOasisStatusText = "Installed (v\(version))"
                simOasisInstalled = true
                saveAPIKey(key: AppSettings.simOasisVersion, value: version)
            case .notInstalled:
                simOasisStatusText = "Not installed \u{2014} run: pip install camel-oasis"
                simOasisInstalled = false
                saveAPIKey(key: AppSettings.simOasisVersion, value: "")
            case .error(let msg):
                simOasisStatusText = msg
                simOasisInstalled = false
                saveAPIKey(key: AppSettings.simOasisVersion, value: "")
            case .pythonNotFound:
                simOasisStatusText = "Python not found"
                simOasisInstalled = false
                saveAPIKey(key: AppSettings.simOasisVersion, value: "")
            }
        } else {
            simPythonDetectedPath = "Not found"
            simOasisStatusText = "Python not found"
            simOasisInstalled = false
            saveAPIKey(key: AppSettings.simDetectedPythonPath, value: "")
            saveAPIKey(key: AppSettings.simOasisVersion, value: "")
        }

        isCheckingEnvironment = false
    }

    // MARK: - Embedding Dimension Mismatch Detection

    /// Checks whether the effective embedding dimension for the current provider
    /// differs from what the vec0 tables were built with, and graph data exists.
    func checkEmbeddingDimensionMismatch() {
        do {
            needsGraphRebuild = try database.read { db in
                let effectiveDim = try AppSettings.effectiveEmbeddingDimension(db)

                let activeDim: Int
                if let setting = try AppSettings
                    .filter(AppSettings.Columns.key == AppSettings.activeEmbeddingDimension)
                    .fetchOne(db),
                   let value = Int(setting.value) {
                    activeDim = value
                } else {
                    activeDim = 0
                }

                guard effectiveDim != activeDim else { return false }

                // Only warn if there's existing graph data that would conflict
                let nodeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node") ?? 0
                return nodeCount > 0
            }
        } catch {
            needsGraphRebuild = false
        }
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
