import XCTest
@testable import NewsCombApp

/// Tests for `SettingsCategory`, which groups `app_settings` keys into UI-facing
/// categories (extraction, clustering, RAG, analysis, LLM, feeds, simulation) and
/// surfaces the set of "secret" keys whose values should never be logged.
final class SettingsCategoryTests: XCTestCase {

    // MARK: - Per-category content

    func testExtractionCategoryContainsExpectedKeys() {
        let keys = SettingsCategory.extraction.keys
        XCTAssertTrue(keys.contains(AppSettings.extractionSystemPrompt))
        XCTAssertTrue(keys.contains(AppSettings.distillationSystemPrompt))
        XCTAssertTrue(keys.contains(AppSettings.distillationEnabled))
        XCTAssertTrue(keys.contains(AppSettings.onDeviceExtractionPrompt))
        XCTAssertTrue(keys.contains(AppSettings.chunkSize))
        XCTAssertTrue(keys.contains(AppSettings.onDeviceChunkSize))
        XCTAssertTrue(keys.contains(AppSettings.extractionTemperature))
    }

    func testClusteringCategoryContainsExpectedKeys() {
        let keys = SettingsCategory.clustering.keys
        XCTAssertTrue(keys.contains(AppSettings.pcaIntermediateDimension))
        XCTAssertTrue(keys.contains(AppSettings.umapTargetDimension))
        XCTAssertTrue(keys.contains(AppSettings.umapNNeighbors))
        XCTAssertTrue(keys.contains(AppSettings.hdbscanMinClusterSize))
        XCTAssertTrue(keys.contains(AppSettings.hdbscanMinSamples))
        XCTAssertTrue(keys.contains(AppSettings.clusterMergeThreshold))
        XCTAssertTrue(keys.contains(AppSettings.noisePoolIQRMultiplier))
        XCTAssertTrue(keys.contains(AppSettings.clusterLabelingSystemPrompt))
    }

    func testRAGCategoryContainsExpectedKeys() {
        let keys = SettingsCategory.rag.keys
        XCTAssertTrue(keys.contains(AppSettings.similarityThreshold))
        XCTAssertTrue(keys.contains(AppSettings.ragMaxNodes))
        XCTAssertTrue(keys.contains(AppSettings.ragMaxChunks))
        XCTAssertTrue(keys.contains(AppSettings.maxPathDepth))
    }

    func testAnalysisCategoryContainsExpectedKeys() {
        let keys = SettingsCategory.analysis.keys
        XCTAssertTrue(keys.contains(AppSettings.engineerAgentPrompt))
        XCTAssertTrue(keys.contains(AppSettings.hypothesizerAgentPrompt))
        XCTAssertTrue(keys.contains(AppSettings.analysisLLMProvider))
        XCTAssertTrue(keys.contains(AppSettings.analysisOllamaEndpoint))
        XCTAssertTrue(keys.contains(AppSettings.analysisOllamaModel))
        XCTAssertTrue(keys.contains(AppSettings.analysisOpenRouterModel))
        XCTAssertTrue(keys.contains(AppSettings.analysisTemperature))
    }

    func testLLMCategoryContainsExpectedKeys() {
        let keys = SettingsCategory.llm.keys
        XCTAssertTrue(keys.contains(AppSettings.llmProvider))
        XCTAssertTrue(keys.contains(AppSettings.ollamaEndpoint))
        XCTAssertTrue(keys.contains(AppSettings.ollamaModel))
        XCTAssertTrue(keys.contains(AppSettings.openRouterModel))
        XCTAssertTrue(keys.contains(AppSettings.openRouterKey))
        XCTAssertTrue(keys.contains(AppSettings.embeddingProvider))
        XCTAssertTrue(keys.contains(AppSettings.embeddingDimension))
        XCTAssertTrue(keys.contains(AppSettings.embeddingOpenRouterModel))
        XCTAssertTrue(keys.contains(AppSettings.llmMaxTokens))
        XCTAssertTrue(keys.contains(AppSettings.maxConcurrentProcessing))
    }

    func testFeedsCategoryContainsExpectedKeys() {
        let keys = SettingsCategory.feeds.keys
        XCTAssertTrue(keys.contains(AppSettings.articleAgeLimitDays))
    }

    func testSimulationCategoryIsEmptyForNow() {
        // Phase 1A leaves simulation empty; sim feature lands later.
        XCTAssertTrue(SettingsCategory.simulation.keys.isEmpty)
    }

    // MARK: - Non-empty categories

    func testNonSimulationCategoriesAreNonEmpty() {
        for category in SettingsCategory.allCases where category != .simulation {
            XCTAssertFalse(
                category.keys.isEmpty,
                "Category \(category.rawValue) should not be empty"
            )
        }
    }

    // MARK: - Secret keys

    func testSecretKeysContainsOpenRouterKey() {
        XCTAssertTrue(SettingsCategory.secretKeys.contains(AppSettings.openRouterKey))
    }

    // MARK: - Uniqueness

    func testKeysAreUniqueAcrossCategories() {
        var seen: [String: SettingsCategory] = [:]
        for category in SettingsCategory.allCases {
            for key in category.keys {
                if let existing = seen[key] {
                    XCTFail(
                        "Key \"\(key)\" appears in both \(existing.rawValue) and \(category.rawValue)"
                    )
                }
                seen[key] = category
            }
        }
    }

    func testNoCategoryContainsDuplicateKeys() {
        for category in SettingsCategory.allCases {
            let keys = category.keys
            XCTAssertEqual(
                keys.count,
                Set(keys).count,
                "Category \(category.rawValue) contains duplicate keys"
            )
        }
    }
}
