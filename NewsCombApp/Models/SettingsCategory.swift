import Foundation

/// Logical grouping of `app_settings` keys for UI surfaces and access control.
///
/// Used by Phase 1A of issues #35 / #36 to drive the new Settings sub-pages and
/// to mark which keys carry sensitive values (e.g. API keys) so they can be
/// masked in logs and UI.
enum SettingsCategory: String, CaseIterable, Sendable {
    case extraction
    case clustering
    case rag
    case analysis
    case llm
    case feeds
    case simulation

    /// All `AppSettings` keys belonging to this category, in the order they should
    /// appear in the UI.
    var keys: [String] {
        switch self {
        case .extraction:
            return [
                AppSettings.extractionSystemPrompt,
                AppSettings.distillationSystemPrompt,
                AppSettings.distillationEnabled,
                AppSettings.onDeviceExtractionPrompt,
                AppSettings.chunkSize,
                AppSettings.onDeviceChunkSize,
                AppSettings.extractionTemperature
            ]
        case .clustering:
            return [
                AppSettings.pcaIntermediateDimension,
                AppSettings.umapTargetDimension,
                AppSettings.umapNNeighbors,
                AppSettings.hdbscanMinClusterSize,
                AppSettings.hdbscanMinSamples,
                AppSettings.clusterMergeThreshold,
                AppSettings.noisePoolIQRMultiplier,
                AppSettings.clusterLabelingSystemPrompt
            ]
        case .rag:
            return [
                AppSettings.similarityThreshold,
                AppSettings.ragMaxNodes,
                AppSettings.ragMaxChunks,
                AppSettings.maxPathDepth
            ]
        case .analysis:
            return [
                AppSettings.engineerAgentPrompt,
                AppSettings.hypothesizerAgentPrompt,
                AppSettings.analysisLLMProvider,
                AppSettings.analysisOllamaEndpoint,
                AppSettings.analysisOllamaModel,
                AppSettings.analysisOpenRouterModel,
                AppSettings.analysisTemperature
            ]
        case .llm:
            return [
                AppSettings.llmProvider,
                AppSettings.ollamaEndpoint,
                AppSettings.ollamaModel,
                AppSettings.openRouterModel,
                AppSettings.openRouterKey,
                AppSettings.embeddingProvider,
                AppSettings.embeddingDimension,
                AppSettings.embeddingOpenRouterModel,
                AppSettings.llmMaxTokens,
                AppSettings.maxConcurrentProcessing
            ]
        case .feeds:
            return [AppSettings.articleAgeLimitDays]
        case .simulation:
            // swiftlint:disable:next todo
            // TODO: enumerate simulation keys when sim feature lands
            return []
        }
    }

    /// Keys whose values are sensitive (API tokens, passwords) and must never be
    /// logged in clear text.
    static let secretKeys: Set<String> = [AppSettings.openRouterKey]

    /// Returns the category that owns `key`, or `nil` if no category claims it.
    ///
    /// Used by Phase 3 of issue #36 (parameter-preset MCP tools). Keys belong
    /// to exactly one category; the lookup walks `SettingsCategory.allCases`
    /// in declared order and returns the first match.
    static func category(forKey key: String) -> SettingsCategory? {
        for category in SettingsCategory.allCases where category.keys.contains(key) {
            return category
        }
        return nil
    }
}
