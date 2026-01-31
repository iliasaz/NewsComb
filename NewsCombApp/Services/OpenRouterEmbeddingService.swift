import Foundation
import OSLog

/// Calls the OpenRouter `/api/v1/embeddings` endpoint (OpenAI-compatible)
/// to generate vector embeddings for text.
final class OpenRouterEmbeddingService: Sendable {
    private let apiKey: String
    private let model: String
    private let dimensions: Int
    private let baseURL: URL
    private let logger = Logger(subsystem: "com.newscomb.app", category: "OpenRouterEmbedding")

    init(
        apiKey: String,
        model: String = AppSettings.defaultEmbeddingOpenRouterModel,
        dimensions: Int = AppSettings.defaultEmbeddingDimension,
        baseURL: URL = URL(string: "https://openrouter.ai")!
    ) {
        self.apiKey = apiKey
        self.model = model
        self.dimensions = dimensions
        self.baseURL = baseURL
    }

    // MARK: - Public API

    /// Embeds a single text string, returning a Float array.
    @concurrent
    func embed(_ text: String) async throws -> [Float] {
        let results = try await embed([text])
        guard let first = results.first else {
            throw OpenRouterEmbeddingError.noEmbeddingReturned
        }
        return first
    }

    /// Embeds multiple text strings in a single request.
    @concurrent
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let url = baseURL.appending(path: "api/v1/embeddings")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let body = EmbeddingRequest(
            model: model,
            input: texts,
            dimensions: dimensions
        )
        request.httpBody = try JSONEncoder().encode(body)

        logger.debug("Requesting embeddings for \(texts.count) text(s), model=\(self.model), dim=\(self.dimensions)")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw OpenRouterEmbeddingError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? "<unreadable>"
            logger.error("OpenRouter embedding API error \(httpResponse.statusCode): \(body, privacy: .public)")
            throw OpenRouterEmbeddingError.apiError(
                statusCode: httpResponse.statusCode,
                message: body
            )
        }

        let decoded = try JSONDecoder().decode(EmbeddingResponse.self, from: data)

        // Sort by index to preserve input order
        let sorted = decoded.data.sorted { $0.index < $1.index }
        return sorted.map { item in
            item.embedding.map { Float($0) }
        }
    }

    // MARK: - Request / Response Models

    private struct EmbeddingRequest: Encodable {
        let model: String
        let input: [String]
        let dimensions: Int
    }

    private struct EmbeddingResponse: Decodable {
        let data: [EmbeddingData]

        struct EmbeddingData: Decodable {
            let embedding: [Double]
            let index: Int
        }
    }
}

// MARK: - Errors

enum OpenRouterEmbeddingError: Error, LocalizedError {
    case noEmbeddingReturned
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case missingAPIKey

    var errorDescription: String? {
        switch self {
        case .noEmbeddingReturned:
            return "OpenRouter returned no embedding data."
        case .invalidResponse:
            return "Invalid response from OpenRouter embedding API."
        case .apiError(let code, let message):
            return "OpenRouter embedding API error (\(code)): \(message)"
        case .missingAPIKey:
            return "OpenRouter API key is not configured. Set it in Settings."
        }
    }
}
