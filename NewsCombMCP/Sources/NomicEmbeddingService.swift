import Embeddings
import Foundation
import OSLog

/// On-device embedding service using the Nomic Embed Text v1.5 model
/// via the `swift-embeddings` library and Apple's MLTensor.
///
/// Mirrors the main app's NomicEmbeddingService but scoped to the MCP server.
/// Uses an actor to serialize GPU encode calls, preventing concurrent crashes.
actor NomicEmbeddingService {
    /// The Hugging Face model identifier.
    nonisolated static let modelName = "nomic-ai/nomic-embed-text-v1.5"

    /// The fixed embedding dimension produced by nomic-embed-text-v1.5.
    nonisolated static let embeddingDimension = 768

    private let logger = Logger(subsystem: "com.newscomb.mcp", category: "NomicEmbedding")

    /// Shared singleton.
    static let shared = NomicEmbeddingService()

    // MARK: - Model Loading State

    private var cachedBundle: NomicBert.ModelBundle?
    private var loadingTask: Task<NomicBert.ModelBundle, any Error>?

    private init() {}

    // MARK: - Model Loading

    /// Returns the cached model bundle, downloading it on first use.
    private func modelBundle() async throws -> NomicBert.ModelBundle {
        if let cachedBundle {
            return cachedBundle
        }

        if let loadingTask {
            return try await loadingTask.value
        }

        let task = Task {
            logger.info("Loading Nomic embedding model from Hugging Face Hub: \(NomicEmbeddingService.modelName, privacy: .public)")
            let bundle = try await NomicBert.loadModelBundle(
                from: NomicEmbeddingService.modelName
            )
            logger.info("Nomic embedding model loaded successfully")
            return bundle
        }
        loadingTask = task

        do {
            let bundle = try await task.value
            cachedBundle = bundle
            loadingTask = nil
            return bundle
        } catch {
            loadingTask = nil
            throw error
        }
    }

    // MARK: - Public API

    /// Embeds a single text string, returning a Float array of dimension 768.
    func embed(_ text: String) async throws -> [Float] {
        let bundle = try await modelBundle()
        let tensor = try bundle.encode(text, postProcess: .meanPoolAndNormalize)
        let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
        return scalars
    }

    /// Converts a Float array embedding to Data for use with sqlite-vec.
    nonisolated static func embeddingToData(_ embedding: [Float]) -> Data {
        embedding.withUnsafeBufferPointer { buffer in
            Data(buffer: buffer)
        }
    }
}
