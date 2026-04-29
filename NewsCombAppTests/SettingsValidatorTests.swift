import XCTest
@testable import NewsCombApp

/// Tests for `SettingsValidator.validate(_:_:)`. Each settings key has at least one
/// passing case (`XCTAssertNoThrow`) and at least one failing case
/// (`XCTAssertThrowsError`) verifying the appropriate `ValidationError` variant.
final class SettingsValidatorTests: XCTestCase {

    // MARK: - Helpers

    private func assertOutOfRange(
        _ key: String,
        _ value: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try SettingsValidator.validate(key, value), file: file, line: line) { error in
            guard let validationError = error as? SettingsValidator.ValidationError else {
                return XCTFail("Expected ValidationError, got \(error)", file: file, line: line)
            }
            if case .outOfRange = validationError { return }
            XCTFail("Expected .outOfRange, got \(validationError)", file: file, line: line)
        }
    }

    private func assertWrongType(
        _ key: String,
        _ value: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try SettingsValidator.validate(key, value), file: file, line: line) { error in
            guard let validationError = error as? SettingsValidator.ValidationError else {
                return XCTFail("Expected ValidationError, got \(error)", file: file, line: line)
            }
            if case .wrongType = validationError { return }
            XCTFail("Expected .wrongType, got \(validationError)", file: file, line: line)
        }
    }

    private func assertInvalidEnum(
        _ key: String,
        _ value: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try SettingsValidator.validate(key, value), file: file, line: line) { error in
            guard let validationError = error as? SettingsValidator.ValidationError else {
                return XCTFail("Expected ValidationError, got \(error)", file: file, line: line)
            }
            if case .invalidEnum = validationError { return }
            XCTFail("Expected .invalidEnum, got \(validationError)", file: file, line: line)
        }
    }

    private func assertEmpty(
        _ key: String,
        _ value: String,
        file: StaticString = #file,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(try SettingsValidator.validate(key, value), file: file, line: line) { error in
            guard let validationError = error as? SettingsValidator.ValidationError else {
                return XCTFail("Expected ValidationError, got \(error)", file: file, line: line)
            }
            if case .empty = validationError { return }
            XCTFail("Expected .empty, got \(validationError)", file: file, line: line)
        }
    }

    // MARK: - Unknown key

    func testUnknownKeyThrows() {
        XCTAssertThrowsError(try SettingsValidator.validate("definitely_not_a_real_key", "x")) { error in
            guard let validationError = error as? SettingsValidator.ValidationError else {
                return XCTFail("Expected ValidationError, got \(error)")
            }
            if case .unknownKey(let key) = validationError {
                XCTAssertEqual(key, "definitely_not_a_real_key")
            } else {
                XCTFail("Expected .unknownKey, got \(validationError)")
            }
        }
    }

    // MARK: - Int bounds

    func testArticleAgeLimitDays() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.articleAgeLimitDays, "7"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.articleAgeLimitDays, "1"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.articleAgeLimitDays, "365"))
        assertOutOfRange(AppSettings.articleAgeLimitDays, "0")
        assertOutOfRange(AppSettings.articleAgeLimitDays, "366")
        assertWrongType(AppSettings.articleAgeLimitDays, "abc")
    }

    func testOnDeviceChunkSize() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.onDeviceChunkSize, "600"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.onDeviceChunkSize, "200"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.onDeviceChunkSize, "1200"))
        assertOutOfRange(AppSettings.onDeviceChunkSize, "199")
        assertOutOfRange(AppSettings.onDeviceChunkSize, "1201")
        assertWrongType(AppSettings.onDeviceChunkSize, "big")
    }

    func testEmbeddingDimension() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.embeddingDimension, "768"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.embeddingDimension, "256"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.embeddingDimension, "2560"))
        assertOutOfRange(AppSettings.embeddingDimension, "255")
        assertOutOfRange(AppSettings.embeddingDimension, "2561")
        assertWrongType(AppSettings.embeddingDimension, "")
    }

    func testChunkSize() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.chunkSize, "800"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.chunkSize, "200"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.chunkSize, "2000"))
        assertOutOfRange(AppSettings.chunkSize, "199")
        assertOutOfRange(AppSettings.chunkSize, "2001")
        assertWrongType(AppSettings.chunkSize, "huge")
    }

    func testUMAPTargetDimension() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.umapTargetDimension, "25"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.umapTargetDimension, "5"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.umapTargetDimension, "100"))
        assertOutOfRange(AppSettings.umapTargetDimension, "4")
        assertOutOfRange(AppSettings.umapTargetDimension, "101")
        assertWrongType(AppSettings.umapTargetDimension, "x")
    }

    func testHDBSCANMinClusterSize() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.hdbscanMinClusterSize, "0"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.hdbscanMinClusterSize, "500"))
        assertOutOfRange(AppSettings.hdbscanMinClusterSize, "-1")
        assertOutOfRange(AppSettings.hdbscanMinClusterSize, "501")
        assertWrongType(AppSettings.hdbscanMinClusterSize, "x")
    }

    func testHDBSCANMinSamples() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.hdbscanMinSamples, "10"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.hdbscanMinSamples, "2"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.hdbscanMinSamples, "50"))
        assertOutOfRange(AppSettings.hdbscanMinSamples, "1")
        assertOutOfRange(AppSettings.hdbscanMinSamples, "51")
        assertWrongType(AppSettings.hdbscanMinSamples, "x")
    }

    func testLLMMaxTokens() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.llmMaxTokens, "2048"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.llmMaxTokens, "256"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.llmMaxTokens, "8192"))
        assertOutOfRange(AppSettings.llmMaxTokens, "255")
        assertOutOfRange(AppSettings.llmMaxTokens, "8193")
        assertWrongType(AppSettings.llmMaxTokens, "x")
    }

    func testRAGMaxNodes() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ragMaxNodes, "10"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ragMaxNodes, "1"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ragMaxNodes, "50"))
        assertOutOfRange(AppSettings.ragMaxNodes, "0")
        assertOutOfRange(AppSettings.ragMaxNodes, "51")
        assertWrongType(AppSettings.ragMaxNodes, "x")
    }

    func testRAGMaxChunks() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ragMaxChunks, "5"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ragMaxChunks, "1"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ragMaxChunks, "20"))
        assertOutOfRange(AppSettings.ragMaxChunks, "0")
        assertOutOfRange(AppSettings.ragMaxChunks, "21")
        assertWrongType(AppSettings.ragMaxChunks, "x")
    }

    func testMaxPathDepth() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.maxPathDepth, "4"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.maxPathDepth, "1"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.maxPathDepth, "8"))
        assertOutOfRange(AppSettings.maxPathDepth, "0")
        assertOutOfRange(AppSettings.maxPathDepth, "9")
        assertWrongType(AppSettings.maxPathDepth, "x")
    }

    func testMaxConcurrentProcessing() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.maxConcurrentProcessing, "10"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.maxConcurrentProcessing, "1"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.maxConcurrentProcessing, "20"))
        assertOutOfRange(AppSettings.maxConcurrentProcessing, "0")
        assertOutOfRange(AppSettings.maxConcurrentProcessing, "21")
        assertWrongType(AppSettings.maxConcurrentProcessing, "x")
    }

    func testPCAIntermediateDimension() {
        // Bound observed in SettingsView Stepper: 10...200.
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.pcaIntermediateDimension, "50"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.pcaIntermediateDimension, "10"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.pcaIntermediateDimension, "200"))
        assertOutOfRange(AppSettings.pcaIntermediateDimension, "9")
        assertOutOfRange(AppSettings.pcaIntermediateDimension, "201")
        assertWrongType(AppSettings.pcaIntermediateDimension, "x")
    }

    func testUMAPNNeighbors() {
        // Bound observed in SettingsView Stepper: 5...50.
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.umapNNeighbors, "15"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.umapNNeighbors, "5"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.umapNNeighbors, "50"))
        assertOutOfRange(AppSettings.umapNNeighbors, "4")
        assertOutOfRange(AppSettings.umapNNeighbors, "51")
        assertWrongType(AppSettings.umapNNeighbors, "x")
    }

    // MARK: - Float bounds

    func testExtractionTemperature() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.extractionTemperature, "0.33"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.extractionTemperature, "0.0"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.extractionTemperature, "2.0"))
        assertOutOfRange(AppSettings.extractionTemperature, "-0.1")
        assertOutOfRange(AppSettings.extractionTemperature, "2.1")
        assertWrongType(AppSettings.extractionTemperature, "warm")
    }

    func testAnalysisTemperature() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisTemperature, "0.7"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisTemperature, "0.0"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisTemperature, "2.0"))
        assertOutOfRange(AppSettings.analysisTemperature, "-0.1")
        assertOutOfRange(AppSettings.analysisTemperature, "2.1")
        assertWrongType(AppSettings.analysisTemperature, "x")
    }

    func testSimilarityThreshold() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.similarityThreshold, "0.9"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.similarityThreshold, "0.0"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.similarityThreshold, "1.0"))
        assertOutOfRange(AppSettings.similarityThreshold, "-0.01")
        assertOutOfRange(AppSettings.similarityThreshold, "1.01")
        assertWrongType(AppSettings.similarityThreshold, "x")
    }

    func testClusterMergeThreshold() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.clusterMergeThreshold, "0.85"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.clusterMergeThreshold, "0.0"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.clusterMergeThreshold, "1.0"))
        assertOutOfRange(AppSettings.clusterMergeThreshold, "-0.01")
        assertOutOfRange(AppSettings.clusterMergeThreshold, "1.01")
        assertWrongType(AppSettings.clusterMergeThreshold, "x")
    }

    func testNoisePoolIQRMultiplier() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.noisePoolIQRMultiplier, "1.5"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.noisePoolIQRMultiplier, "0.1"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.noisePoolIQRMultiplier, "10.0"))
        assertOutOfRange(AppSettings.noisePoolIQRMultiplier, "0.0")
        assertOutOfRange(AppSettings.noisePoolIQRMultiplier, "-0.1")
        assertOutOfRange(AppSettings.noisePoolIQRMultiplier, "10.1")
        assertWrongType(AppSettings.noisePoolIQRMultiplier, "x")
    }

    // MARK: - Enum-string keys

    func testLLMProviderAcceptsAllowedValues() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.llmProvider, ""))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.llmProvider, "ollama"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.llmProvider, "openrouter"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.llmProvider, "on_device"))
        assertInvalidEnum(AppSettings.llmProvider, "claude")
    }

    func testAnalysisLLMProviderAcceptsAllowedValues() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisLLMProvider, ""))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisLLMProvider, "ollama"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisLLMProvider, "openrouter"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisLLMProvider, "on_device"))
        assertInvalidEnum(AppSettings.analysisLLMProvider, "gpt4")
    }

    func testEmbeddingProviderAcceptsAllowedValues() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.embeddingProvider, "on_device"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.embeddingProvider, "openrouter"))
        assertInvalidEnum(AppSettings.embeddingProvider, "ollama")
        assertInvalidEnum(AppSettings.embeddingProvider, "")
    }

    // MARK: - Non-empty prompt strings

    func testExtractionSystemPrompt() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.extractionSystemPrompt, "extract triples"))
        assertEmpty(AppSettings.extractionSystemPrompt, "")
        assertEmpty(AppSettings.extractionSystemPrompt, "   \n\t ")
    }

    func testDistillationSystemPrompt() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.distillationSystemPrompt, "summarize"))
        assertEmpty(AppSettings.distillationSystemPrompt, "")
    }

    func testClusterLabelingSystemPrompt() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.clusterLabelingSystemPrompt, "label clusters"))
        assertEmpty(AppSettings.clusterLabelingSystemPrompt, "")
    }

    func testOnDeviceExtractionPrompt() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.onDeviceExtractionPrompt, "extract"))
        assertEmpty(AppSettings.onDeviceExtractionPrompt, "")
    }

    func testEngineerAgentPrompt() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.engineerAgentPrompt, "engineer"))
        assertEmpty(AppSettings.engineerAgentPrompt, "")
    }

    func testHypothesizerAgentPrompt() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.hypothesizerAgentPrompt, "hypothesize"))
        assertEmpty(AppSettings.hypothesizerAgentPrompt, "")
    }

    // MARK: - Endpoints

    func testOllamaEndpoint() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ollamaEndpoint, "http://localhost:11434"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ollamaEndpoint, "https://ollama.example.com"))
        assertEmpty(AppSettings.ollamaEndpoint, "")
        // Must start with http(s).
        XCTAssertThrowsError(try SettingsValidator.validate(AppSettings.ollamaEndpoint, "ftp://x"))
        XCTAssertThrowsError(try SettingsValidator.validate(AppSettings.ollamaEndpoint, "localhost:11434"))
    }

    func testAnalysisOllamaEndpoint() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisOllamaEndpoint, "http://localhost:11434"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisOllamaEndpoint, "https://x.com"))
        assertEmpty(AppSettings.analysisOllamaEndpoint, "")
        XCTAssertThrowsError(try SettingsValidator.validate(AppSettings.analysisOllamaEndpoint, "not-a-url"))
    }

    // MARK: - Model strings (non-empty)

    func testOllamaModel() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.ollamaModel, "llama3.2:3b"))
        assertEmpty(AppSettings.ollamaModel, "")
    }

    func testAnalysisOllamaModel() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisOllamaModel, "llama3.2:3b"))
        assertEmpty(AppSettings.analysisOllamaModel, "")
    }

    func testOpenRouterModel() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.openRouterModel, "meta-llama/llama-4-maverick"))
        assertEmpty(AppSettings.openRouterModel, "")
    }

    func testAnalysisOpenRouterModel() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.analysisOpenRouterModel, "meta-llama/llama-4-maverick"))
        assertEmpty(AppSettings.analysisOpenRouterModel, "")
    }

    func testEmbeddingOpenRouterModel() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.embeddingOpenRouterModel, "openai/text-embedding-3-large"))
        assertEmpty(AppSettings.embeddingOpenRouterModel, "")
    }

    // MARK: - openRouterKey: any string allowed (including empty so user can clear it)

    func testOpenRouterKeyAcceptsAnyString() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.openRouterKey, "sk-secret"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.openRouterKey, ""))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.openRouterKey, "   "))
    }

    // MARK: - Bool string

    func testDistillationEnabledAcceptsBoolStrings() {
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.distillationEnabled, "true"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.distillationEnabled, "false"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.distillationEnabled, "1"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.distillationEnabled, "0"))
        // Case insensitive accepted.
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.distillationEnabled, "TRUE"))
        XCTAssertNoThrow(try SettingsValidator.validate(AppSettings.distillationEnabled, "False"))
        assertWrongType(AppSettings.distillationEnabled, "yes")
        assertWrongType(AppSettings.distillationEnabled, "")
    }
}
