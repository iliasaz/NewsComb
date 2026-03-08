import Embeddings
import Foundation
import OSLog

/// On-device embedding service using the Nomic Embed Text v1.5 model
/// via the `swift-embeddings` library and Apple's MLTensor.
///
/// Converted to an actor to serialize all `bundle.encode()` calls,
/// preventing concurrent MPSGraph/sdpa() GPU crashes.
/// An internal continuation-based queue ensures that while one encode
/// + GPU materialization is in flight, new callers are queued and
/// processed in order.
actor NomicEmbeddingService {
    /// The Hugging Face model identifier.
    nonisolated static let modelName = "nomic-ai/nomic-embed-text-v1.5"

    /// The fixed embedding dimension produced by nomic-embed-text-v1.5.
    nonisolated static let embeddingDimension = 768

    nonisolated(unsafe) private let logger = Logger(subsystem: "com.newscomb.app", category: "NomicEmbedding")

    /// Shared singleton — safe to reuse across the app.
    static let shared = NomicEmbeddingService()

    // MARK: - Model Loading State (inlined from former ModelHolder)

    private var cachedBundle: NomicBert.ModelBundle?
    private var loadingTask: Task<NomicBert.ModelBundle, any Error>?

    // MARK: - Encode Queue

    /// A pending encode request with its texts and a continuation to resume the caller.
    private struct EncodeRequest {
        let texts: [String]
        let continuation: CheckedContinuation<[[Float]], any Error>
    }

    private var encodeQueue: [EncodeRequest] = []
    private var isProcessingQueue = false

    private init() {}

    // MARK: - Model Loading

    /// Returns the cached model bundle, downloading it on first use.
    /// Uses a coalescing Task to handle actor reentrancy: when the first
    /// caller awaits the download, subsequent callers await the *same*
    /// Task instead of starting a second download.
    private func modelBundle() async throws -> NomicBert.ModelBundle {
        if let cachedBundle {
            return cachedBundle
        }

        // If a download is already in flight, await it instead of starting another.
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

    /// Ensures the model is downloaded and ready before concurrent work begins.
    /// Call this once before spawning parallel embedding tasks.
    func ensureModelLoaded() async throws {
        _ = try await modelBundle()
    }

    /// Embeds a single text string, returning a Float array of dimension 768.
    func embed(_ text: String) async throws -> [Float] {
        let results = try await enqueueEncode(texts: [text])
        return results[0]
    }

    /// Embeds multiple text strings, returning an array of Float arrays.
    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        return try await enqueueEncode(texts: texts)
    }

    // MARK: - Encode Queue Implementation

    /// Enqueues an encode request and returns the result via a continuation.
    /// If the queue processor is not running, starts it.
    private func enqueueEncode(texts: [String]) async throws -> [[Float]] {
        try await withCheckedThrowingContinuation { continuation in
            encodeQueue.append(EncodeRequest(texts: texts, continuation: continuation))

            if !isProcessingQueue {
                isProcessingQueue = true
                Task { await processEncodeQueue() }
            }
        }
    }

    /// Drains the encode queue one request at a time, serializing all
    /// GPU work. When this method suspends at `await shapedArray()`,
    /// the actor can be re-entered by `enqueueEncode()` — but the
    /// re-entrant call sees `isProcessingQueue == true` and does not
    /// start a second processing loop.
    private func processEncodeQueue() async {
        while !encodeQueue.isEmpty {
            let request = encodeQueue.removeFirst()

            do {
                let bundle = try await modelBundle()

                var results: [[Float]] = []
                results.reserveCapacity(request.texts.count)

                for text in request.texts {
                    let tensor = try bundle.encode(text, postProcess: .meanPoolAndNormalize)
                    let scalars = await tensor.cast(to: Float.self).shapedArray(of: Float.self).scalars
                    results.append(scalars)
                }

                request.continuation.resume(returning: results)
            } catch {
                request.continuation.resume(throwing: error)
            }
        }

        // Synchronous check — no await between isEmpty check and flag reset,
        // so no request can be missed.
        isProcessingQueue = false
    }
}
