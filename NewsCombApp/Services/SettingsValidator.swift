import Foundation

/// Validates `app_settings` key/value pairs before they're written to the database.
///
/// Phase 1A of issues #35 / #36. Used by the MCP write tool and the Settings UI
/// to surface human-readable errors when a value is missing, mistyped, or
/// out-of-range. Bounds match those enforced by `SettingsView`'s Steppers.
enum SettingsValidator {

    /// Errors thrown by `validate(_:_:)`. All cases carry enough context to be
    /// turned into a useful UI message via `errorDescription`.
    enum ValidationError: Error, LocalizedError, Equatable {
        case unknownKey(String)
        case wrongType(key: String, expected: String, got: String)
        case outOfRange(key: String, value: String, allowed: String)
        case invalidEnum(key: String, value: String, allowed: String)
        case empty(key: String)

        var errorDescription: String? {
            switch self {
            case .unknownKey(let key):
                return "Unknown settings key: '\(key)'."
            case .wrongType(let key, let expected, let got):
                return "Setting '\(key)' expected \(expected), got '\(got)'."
            case .outOfRange(let key, let value, let allowed):
                return "Setting '\(key)' value '\(value)' is out of range. Allowed: \(allowed)."
            case .invalidEnum(let key, let value, let allowed):
                return "Setting '\(key)' value '\(value)' is not allowed. Allowed: \(allowed)."
            case .empty(let key):
                return "Setting '\(key)' must not be empty."
            }
        }
    }

    /// Validates `value` for the given settings `key`.
    ///
    /// - Throws: `ValidationError` describing the first problem found.
    // swiftlint:disable:next cyclomatic_complexity
    static func validate(_ key: String, _ value: String) throws {
        switch key {
        // MARK: Int bounds

        case AppSettings.articleAgeLimitDays:
            try requireInt(key: key, value: value, range: 1...365)
        case AppSettings.onDeviceChunkSize:
            try requireInt(key: key, value: value, range: 200...1200)
        case AppSettings.embeddingDimension:
            try requireInt(key: key, value: value, range: 256...2560)
        case AppSettings.chunkSize:
            try requireInt(key: key, value: value, range: 200...2000)
        case AppSettings.umapTargetDimension:
            try requireInt(key: key, value: value, range: 5...100)
        case AppSettings.hdbscanMinClusterSize:
            try requireInt(key: key, value: value, range: 0...500)
        case AppSettings.hdbscanMinSamples:
            try requireInt(key: key, value: value, range: 2...50)
        case AppSettings.llmMaxTokens:
            try requireInt(key: key, value: value, range: 256...8192)
        case AppSettings.ragMaxNodes:
            try requireInt(key: key, value: value, range: 1...50)
        case AppSettings.ragMaxChunks:
            try requireInt(key: key, value: value, range: 1...20)
        case AppSettings.maxPathDepth:
            try requireInt(key: key, value: value, range: 1...8)
        case AppSettings.maxConcurrentProcessing:
            try requireInt(key: key, value: value, range: 1...20)
        case AppSettings.pcaIntermediateDimension:
            // Bound matches SettingsView Stepper: 10...200.
            try requireInt(key: key, value: value, range: 10...200)
        case AppSettings.umapNNeighbors:
            // Bound matches SettingsView Stepper: 5...50.
            try requireInt(key: key, value: value, range: 5...50)

        // MARK: Float bounds

        case AppSettings.extractionTemperature,
             AppSettings.analysisTemperature:
            try requireFloat(key: key, value: value, range: 0.0...2.0)
        case AppSettings.similarityThreshold,
             AppSettings.clusterMergeThreshold:
            try requireFloat(key: key, value: value, range: 0.0...1.0)
        case AppSettings.noisePoolIQRMultiplier:
            try requireFloatExclusiveLowerBound(
                key: key,
                value: value,
                lowerBound: 0.0,
                upperBound: 10.0
            )

        // MARK: Enum-string keys

        case AppSettings.llmProvider, AppSettings.analysisLLMProvider:
            try requireEnum(
                key: key,
                value: value,
                allowed: ["", "ollama", "openrouter", "on_device"]
            )
        case AppSettings.embeddingProvider:
            try requireEnum(
                key: key,
                value: value,
                allowed: ["on_device", "openrouter"]
            )

        // MARK: Non-empty prompts

        case AppSettings.extractionSystemPrompt,
             AppSettings.distillationSystemPrompt,
             AppSettings.clusterLabelingSystemPrompt,
             AppSettings.onDeviceExtractionPrompt,
             AppSettings.engineerAgentPrompt,
             AppSettings.hypothesizerAgentPrompt:
            try requireNonEmpty(key: key, value: value)

        // MARK: Endpoints

        case AppSettings.ollamaEndpoint, AppSettings.analysisOllamaEndpoint:
            try requireHTTPURLString(key: key, value: value)

        // MARK: Non-empty model strings

        case AppSettings.ollamaModel,
             AppSettings.analysisOllamaModel,
             AppSettings.openRouterModel,
             AppSettings.analysisOpenRouterModel,
             AppSettings.embeddingOpenRouterModel:
            try requireNonEmpty(key: key, value: value)

        // MARK: Free-form (any string allowed, including empty)

        case AppSettings.openRouterKey:
            return  // user may want to clear it

        // MARK: Bool-string

        case AppSettings.distillationEnabled:
            try requireBoolString(key: key, value: value)

        default:
            throw ValidationError.unknownKey(key)
        }
    }

    // MARK: - Helpers

    private static func requireInt(
        key: String,
        value: String,
        range: ClosedRange<Int>
    ) throws {
        guard let parsed = Int(value) else {
            throw ValidationError.wrongType(key: key, expected: "Int", got: value)
        }
        guard range.contains(parsed) else {
            throw ValidationError.outOfRange(
                key: key,
                value: value,
                allowed: "\(range.lowerBound)...\(range.upperBound)"
            )
        }
    }

    private static func requireFloat(
        key: String,
        value: String,
        range: ClosedRange<Float>
    ) throws {
        guard let parsed = Float(value) else {
            throw ValidationError.wrongType(key: key, expected: "Float", got: value)
        }
        guard range.contains(parsed) else {
            throw ValidationError.outOfRange(
                key: key,
                value: value,
                allowed: "\(range.lowerBound)...\(range.upperBound)"
            )
        }
    }

    /// Like `requireFloat` but with an exclusive lower bound (e.g. "must be > 0").
    private static func requireFloatExclusiveLowerBound(
        key: String,
        value: String,
        lowerBound: Float,
        upperBound: Float
    ) throws {
        guard let parsed = Float(value) else {
            throw ValidationError.wrongType(key: key, expected: "Float", got: value)
        }
        guard parsed > lowerBound, parsed <= upperBound else {
            throw ValidationError.outOfRange(
                key: key,
                value: value,
                allowed: "(\(lowerBound), \(upperBound)]"
            )
        }
    }

    private static func requireEnum(
        key: String,
        value: String,
        allowed: [String]
    ) throws {
        guard allowed.contains(value) else {
            let list = allowed.map { "'\($0)'" }.joined(separator: ", ")
            throw ValidationError.invalidEnum(key: key, value: value, allowed: list)
        }
    }

    private static func requireNonEmpty(key: String, value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ValidationError.empty(key: key)
        }
    }

    private static func requireHTTPURLString(key: String, value: String) throws {
        try requireNonEmpty(key: key, value: value)
        let lower = value.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            throw ValidationError.wrongType(
                key: key,
                expected: "URL starting with http:// or https://",
                got: value
            )
        }
    }

    private static func requireBoolString(key: String, value: String) throws {
        let normalized = value.lowercased()
        let allowed: Set<String> = ["true", "false", "1", "0"]
        guard allowed.contains(normalized) else {
            throw ValidationError.wrongType(
                key: key,
                expected: "Bool string ('true'/'false'/'1'/'0')",
                got: value
            )
        }
    }
}
