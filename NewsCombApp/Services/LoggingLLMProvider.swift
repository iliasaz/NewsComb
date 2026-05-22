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
        // Log request + response as ONE entry. Under the concurrent chunk pool,
        // separate request/response lines from different chunks interleave and
        // can't be paired; a single entry keeps each prompt with its result.
        do {
            let response = try await wrapped.chat(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                model: model,
                temperature: temperature
            )
            logger.debug("── LLM chat ──\nREQUEST:\n\(userPrompt, privacy: .public)\nRESPONSE:\n\(response, privacy: .public)")
            return response
        } catch {
            logger.debug("── LLM chat (failed) ──\nREQUEST:\n\(userPrompt, privacy: .public)\nERROR: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }

    func generate<T: Decodable & Sendable>(
        systemPrompt: String,
        userPrompt: String,
        responseType: T.Type,
        model: String?,
        temperature: Double?
    ) async throws -> T {
        do {
            let result = try await wrapped.generate(
                systemPrompt: systemPrompt,
                userPrompt: userPrompt,
                responseType: responseType,
                model: model,
                temperature: temperature
            )

            let responseText: String
            if let encodable = result as? any Encodable,
               let jsonData = try? JSONEncoder().encode(encodable),
               let jsonString = String(data: jsonData, encoding: .utf8) {
                responseText = jsonString
            } else {
                responseText = "(type: \(String(describing: T.self)))"
            }
            logger.debug("── LLM generate ──\nREQUEST:\n\(userPrompt, privacy: .public)\nRESPONSE:\n\(responseText, privacy: .public)")
            return result
        } catch {
            logger.debug("── LLM generate (failed) ──\nREQUEST:\n\(userPrompt, privacy: .public)\nERROR: \(error.localizedDescription, privacy: .public)")
            throw error
        }
    }
}
