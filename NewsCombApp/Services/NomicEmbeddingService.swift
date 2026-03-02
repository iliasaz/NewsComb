import Embeddings
import Foundation
import OSLog

/// On-device embedding service using the Nomic Embed Text v1.5 model
/// via the `swift-embeddings` library and Apple's MLTensor.
///
/// The model is lazily downloaded from Hugging Face Hub on first use
/// and cached for the lifetime of the process.
final class NomicEmbeddingService: Sendable {
    /// The Hugging Face model identifier.
    static let modelName = "nomic-ai/nomic-embed-text-v1.5"

    /// The fixed embedding dimension produced by nomic-embed-text-v1.5.
    static let embeddingDimension = 768

    private let logger = Logger(subsystem: "com.newscomb.app", category: "NomicEmbedding")

    /// Shared singleton — safe to reuse across the app.
    static let shared = NomicEmbeddingService()

    /// Lazily loaded model bundle, protected by an actor for thread-safe
    /// one-time initialization.
    private let modelHolder = ModelHolder()

    private init() {}

    // MARK: - Public API

    /// Embeds a single text string, returning a Float array of dimension 768.
    @concurrent
    func embed(_ text: String) async throws -> [Float] {
        let bundle = try await modelHolder.modelBundle(logger: logger)
        let tensor = try bundle.encode(text)
        return await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
    }

    /// Embeds multiple text strings, returning an array of Float arrays.
    @concurrent
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }

        let bundle = try await modelHolder.modelBundle(logger: logger)

        // Process texts individually to get separate embedding vectors.
        // batchEncode returns a single 2D tensor but extracting rows requires
        // dimension slicing which is simpler done per-text for correctness.
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)

        for text in texts {
            let tensor = try bundle.encode(text)
            let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
            results.append(scalars)
        }
        return results
    }
}

// MARK: - Model Holder Actor

/// Actor that ensures the model bundle is loaded exactly once.
private actor ModelHolder {
    private var cachedBundle: NomicBert.ModelBundle?

    func modelBundle(logger: Logger) async throws -> NomicBert.ModelBundle {
        if let cachedBundle {
            return cachedBundle
        }

        logger.info("Loading Nomic embedding model from Hugging Face Hub: \(NomicEmbeddingService.modelName, privacy: .public)")
        let bundle = try await NomicBert.loadModelBundle(
            from: NomicEmbeddingService.modelName
        )
        cachedBundle = bundle
        logger.info("Nomic embedding model loaded successfully")
        return bundle
    }
}
