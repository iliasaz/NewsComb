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
            let result = response.content
            // The model can legitimately complete (no error) while extracting
            // zero events — common for narrative/first-person prose. This is a
            // silent path otherwise (article still marked completed), so surface
            // it with a snippet of the input to make under-extraction visible.
            if result.events.isEmpty {
                logger.notice("On-device extraction returned 0 events (input \(userPrompt.count) chars): \(Self.inputSnippet(userPrompt), privacy: .public)")
            }
            return convertToHypergraphJSON(result)
        } catch let error as LanguageModelSession.GenerationError {
            // Empty/garbled output surfaces as .decodingFailure ("Text: " with
            // no body). Log it with the input snippet before the library's
            // per-chunk catch swallows the rethrown error.
            if case .decodingFailure = error {
                logger.warning("On-device extraction produced empty/unparseable output (input \(userPrompt.count) chars): \(Self.inputSnippet(userPrompt), privacy: .public)")
            }
            throw mapGenerationError(error)
        }
    }

    /// Converts a `GenerableExtractionResult` to `HypergraphJSON`, collapsing
    /// duplicate triples the model sometimes emits in a degenerate loop.
    @available(macOS 26.0, iOS 26.0, *)
    private func convertToHypergraphJSON(_ result: GenerableExtractionResult) -> HypergraphJSON {
        let triples = result.events.map { (source: $0.source, relation: $0.relation, target: $0.target) }
        let (deduped, dropped) = dedupeEvents(triples)
        if dropped > 0 {
            // Visible counterpart to the empty-extraction logging: the model
            // looped on one relationship up to the schema's maximumCount.
            logger.notice("Dropped \(dropped) duplicate event(s), kept \(deduped.count) — model emitted repeated triples (likely degenerate loop)")
        }
        let events = deduped.map { Event(source: $0.source, target: $0.target, relation: $0.relation) }
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

    /// Returns a single-line, truncated view of the extraction input for logs.
    /// Strips the ``` wrapper that `extractionUserPrompt` adds so the log shows
    /// the actual article text that produced no extraction. `internal` (not
    /// `private`) so it can be unit-tested.
    static func inputSnippet(_ userPrompt: String, limit: Int = 240) -> String {
        var text = userPrompt
        if let open = text.range(of: "```"), let close = text.range(of: "```", range: open.upperBound..<text.endIndex) {
            text = String(text[open.upperBound..<close.lowerBound])
        }
        let collapsed = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return collapsed.count > limit ? String(collapsed.prefix(limit)) + "…" : collapsed
    }

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
    let deduped = dedupeEvents(events).events
    let mapped = deduped.map { event in
        Event(
            source: event.source,
            target: event.target,
            relation: event.relation
        )
    }
    return HypergraphJSON(events: mapped)
}

/// Collapses identical relationship triples the on-device model sometimes
/// emits in a degenerate loop (e.g. 14 copies of one event, padding the array
/// up to the schema's `maximumCount`). Without this, each copy becomes a
/// distinct hyperedge because `toHypergraph` suffixes edge IDs with the array
/// index — inflating edge counts, provenance rows, and clustering weights.
///
/// Two triples are duplicates when their relation and their source and target
/// node sets match, compared case- and order-insensitively (so reordered or
/// case-variant repeats also collapse). Keeps the first occurrence; returns the
/// deduped triples and how many were dropped.
func dedupeEvents(
    _ events: [(source: [String], relation: String, target: [String])]
) -> (events: [(source: [String], relation: String, target: [String])], dropped: Int) {
    func normalizedSet(_ items: [String]) -> String {
        items
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .sorted()
            .joined(separator: "\u{1f}")  // unit separator — unlikely in entity text
    }
    var seen = Set<String>()
    var kept: [(source: [String], relation: String, target: [String])] = []
    for event in events {
        let relation = event.relation.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let key = "\(relation)\u{1e}\(normalizedSet(event.source))\u{1e}\(normalizedSet(event.target))"
        if seen.insert(key).inserted {
            kept.append(event)
        }
    }
    return (kept, events.count - kept.count)
}
