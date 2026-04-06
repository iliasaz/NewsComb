import Foundation
import HyperGraphReasoning
import OSLog

/// A decorator that wraps any `LLMProvider` and logs each chunk (userPrompt)
/// and the LLM response at debug level.
///
/// Inject this between the real provider and the `DocumentProcessor` to
/// observe extraction I/O without modifying the package code.
final class LoggingLLMProvider: LLMProvider, Sendable {

    private let wrapped: any LLMProvider
    private nonisolated(unsafe) let logger = Logger(subsystem: "com.newscomb", category: "LLMExtraction")

    var defaultModel: String { wrapped.defaultModel }

    init(wrapping provider: any LLMProvider) {
        self.wrapped = provider
    }

    func chat(
        systemPrompt: String,
        userPrompt: String,
        model: String?,
        temperature: Double?
    ) async throws -> String {
        logger.debug("── LLM chat request ──\n\(userPrompt, privacy: .public)")

        let response = try await wrapped.chat(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            model: model,
            temperature: temperature
        )

        logger.debug("── LLM chat response ──\n\(response, privacy: .public)")
        return response
    }

    func generate<T: Decodable & Sendable>(
        systemPrompt: String,
        userPrompt: String,
        responseType: T.Type,
        model: String?,
        temperature: Double?
    ) async throws -> T {
        logger.debug("── LLM generate request ──\n\(userPrompt, privacy: .public)")

        let result = try await wrapped.generate(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            responseType: responseType,
            model: model,
            temperature: temperature
        )

        if let encodable = result as? any Encodable,
           let jsonData = try? JSONEncoder().encode(encodable),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            logger.debug("── LLM generate response ──\n\(jsonString, privacy: .public)")
        } else {
            logger.debug("── LLM generate response ── (type: \(String(describing: T.self), privacy: .public))")
        }

        return result
    }
}
