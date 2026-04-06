import Foundation
import HyperGraphReasoning
import OSLog

#if canImport(FoundationModels)
import FoundationModels
#endif

private let logger = Logger(subsystem: "com.newscomb", category: "FoundationModel")

// MARK: - Availability

/// Describes the availability of on-device Foundation Models.
enum FoundationModelAvailability: Sendable {
    case available
    case unavailable(reason: String)

    /// Checks whether the on-device Foundation Models framework is available.
    static func check() -> FoundationModelAvailability {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            return .unavailable(reason: "Foundation Models requires macOS 26.0 or iOS 26.0.")
        }
        let model = SystemLanguageModel.default
        switch model.availability {
        case .available:
            return .available
        case .unavailable(.deviceNotEligible):
            return .unavailable(reason: "This device does not support Apple Intelligence.")
        case .unavailable(.appleIntelligenceNotEnabled):
            return .unavailable(reason: "Apple Intelligence is not enabled in Settings.")
        case .unavailable(.modelNotReady):
            return .unavailable(reason: "The on-device model is not ready (may be downloading).")
        case .unavailable:
            return .unavailable(reason: "The on-device model is unavailable.")
        }
        #else
        return .unavailable(reason: "Foundation Models framework is not available on this platform.")
        #endif
    }

    /// A user-facing description of the current availability status.
    var statusDescription: String {
        switch self {
        case .available:
            return "Available"
        case .unavailable(let reason):
            return reason
        }
    }

    /// Whether the model is available.
    var isAvailable: Bool {
        if case .available = self { return true }
        return false
    }
}

// MARK: - Generable Types

#if canImport(FoundationModels)

/// Structured extraction result for on-device hypergraph extraction.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GenerableExtractionResult {
    @Guide(description: "Extracted entity relationships as Subject-Verb-Object triples.", .maximumCount(15))
    var events: [GenerableEvent]
}

/// A single extracted relationship event.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GenerableEvent {
    @Guide(description: "Source entities performing the action.")
    var source: [String]

    @Guide(description: "The verb or relationship connecting source to target.")
    var relation: String

    @Guide(description: "Target entities receiving the action.")
    var target: [String]
}

/// Structured classification result for a batch of nodes.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GenerableClassificationBatch {
    @Guide(description: "Classifications for each entity node.")
    var classifications: [GenerableClassification]
}

/// Classification of a single node.
@available(macOS 26.0, iOS 26.0, *)
@Generable
struct GenerableClassification {
    @Guide(description: "Node database ID.")
    var node_id: Int

    @Guide(description: "Entity type.", .anyOf([
        "person", "organization", "company", "government_entity", "institution", "non-actor"
    ]))
    var type: String
}

#endif

// MARK: - Foundation Model Service

/// On-device LLM provider using Apple Foundation Models.
///
/// Each method creates a fresh `LanguageModelSession` to avoid accumulating
/// tokens in the limited 4096-token context window.
actor FoundationModelService: LLMProvider {

    let defaultModel: String = "apple-on-device"

    func chat(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        temperature: Double?
    ) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw LLMProviderError.configurationError(
                "Foundation Models requires macOS 26.0 or iOS 26.0."
            )
        }
        let session = LanguageModelSession(instructions: Instructions(systemPrompt))
        do {
            let response = try await session.respond(to: Prompt(userPrompt))
            let text = response.content
            if text.isEmpty {
                throw LLMProviderError.invalidResponse("Empty response from on-device model.")
            }
            return text
        } catch let error as LanguageModelSession.GenerationError {
            throw mapGenerationError(error)
        }
        #else
        throw LLMProviderError.configurationError(
            "Foundation Models framework is not available on this platform."
        )
        #endif
    }

    func generate<T: Decodable & Sendable>(
        systemPrompt: String,
        userPrompt: String,
        responseType: T.Type,
        model: String?,
        temperature: Double?
    ) async throws -> T {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, iOS 26.0, *) else {
            throw LLMProviderError.configurationError(
                "Foundation Models requires macOS 26.0 or iOS 26.0."
            )
        }
        // For HypergraphJSON, use the Generable structured generation and convert
        if responseType == HypergraphJSON.self {
            return try await generateExtraction(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt
            ) as! T
        }

        // Fallback: generate text and parse as JSON
        let response = try await chat(
            systemPrompt: systemPrompt + "\n\nIMPORTANT: Respond with valid JSON only. No additional text.",
            userPrompt: userPrompt,
            model: model,
            temperature: temperature
        )

        let jsonString = extractJSON(from: response)
        guard let data = jsonString.data(using: .utf8) else {
            throw LLMProviderError.invalidResponse("Response is not valid UTF-8.")
        }

        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw LLMProviderError.decodingFailed(error)
        }
        #else
        throw LLMProviderError.configurationError(
            "Foundation Models framework is not available on this platform."
        )
        #endif
    }

    // MARK: - Private Helpers

    #if canImport(FoundationModels)

    /// Uses guided generation to produce a structured extraction result, then
    /// converts it to the `HypergraphJSON` type expected by the pipeline.
    @available(macOS 26.0, iOS 26.0, *)
    private func generateExtraction(
        systemPrompt: String,
        userPrompt: String
    ) async throws -> HypergraphJSON {
        let session = LanguageModelSession(instructions: Instructions(systemPrompt))
        do {
            let response = try await session.respond(
                to: Prompt(userPrompt),
                generating: GenerableExtractionResult.self
            )
            return convertToHypergraphJSON(response.content)
        } catch let error as LanguageModelSession.GenerationError {
            throw mapGenerationError(error)
        }
    }

    /// Converts a `GenerableExtractionResult` to `HypergraphJSON`.
    @available(macOS 26.0, iOS 26.0, *)
    private func convertToHypergraphJSON(_ result: GenerableExtractionResult) -> HypergraphJSON {
        let events = result.events.map { event in
            Event(
                source: event.source,
                target: event.target,
                relation: event.relation
            )
        }
        return HypergraphJSON(events: events)
    }

    /// Maps Foundation Models generation errors to `LLMProviderError`.
    @available(macOS 26.0, iOS 26.0, *)
    private func mapGenerationError(_ error: LanguageModelSession.GenerationError) -> LLMProviderError {
        switch error {
        case .guardrailViolation:
            logger.warning("On-device model guardrail violation")
            return .invalidResponse("The on-device model declined due to content safety guardrails.")
        case .exceededContextWindowSize:
            logger.warning("On-device model context window exceeded")
            return .invalidResponse("The input exceeded the on-device model's context window (4096 tokens). Try reducing chunk size.")
        case .rateLimited:
            logger.warning("On-device model rate limited")
            return .connectionFailed(error)
        case .assetsUnavailable:
            return .modelNotAvailable("On-device model assets are unavailable. The model may still be downloading.")
        case .decodingFailure:
            return .decodingFailed(error)
        default:
            logger.error("On-device model error: \(error.localizedDescription, privacy: .public)")
            return .invalidResponse("On-device model error: \(error.localizedDescription)")
        }
    }

    #endif

    /// Extracts JSON from a response that might contain markdown code blocks.
    private func extractJSON(from response: String) -> String {
        var content = response.trimmingCharacters(in: .whitespacesAndNewlines)

        if content.hasPrefix("```json") {
            content = String(content.dropFirst(7))
        } else if content.hasPrefix("```") {
            content = String(content.dropFirst(3))
        }

        if content.hasSuffix("```") {
            content = String(content.dropLast(3))
        }

        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        if !content.hasPrefix("{") && !content.hasPrefix("[") {
            if let jsonStart = content.firstIndex(of: "{") {
                content = String(content[jsonStart...])
            } else if let jsonStart = content.firstIndex(of: "[") {
                content = String(content[jsonStart...])
            }
        }

        if !content.hasSuffix("}") && !content.hasSuffix("]") {
            if let jsonEnd = content.lastIndex(of: "}") {
                content = String(content[...jsonEnd])
            } else if let jsonEnd = content.lastIndex(of: "]") {
                content = String(content[...jsonEnd])
            }
        }

        return content.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Conversion Helpers (testable)

/// Converts a `GenerableExtractionResult`-shaped dictionary to `HypergraphJSON`.
///
/// This is a standalone function for unit testing the conversion logic
/// without requiring the FoundationModels framework.
func convertGenerableEventsToHypergraphJSON(
    events: [(source: [String], relation: String, target: [String])]
) -> HypergraphJSON {
    let mapped = events.map { event in
        Event(
            source: event.source,
            target: event.target,
            relation: event.relation
        )
    }
    return HypergraphJSON(events: mapped)
}
