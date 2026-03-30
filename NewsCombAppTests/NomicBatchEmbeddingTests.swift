import XCTest
@testable import NewsCombApp

/// Tests that batch embedding produces the same results as sequential embedding.
///
/// **Requires:** The Nomic model to be downloaded (first run may be slow).
/// These tests verify that `batchEncode` gives equivalent results to individual
/// `encode` calls, ensuring the batch optimization doesn't change output quality.
@MainActor
final class NomicBatchEmbeddingTests: XCTestCase {

    private let service = NomicEmbeddingService.shared

    // MARK: - Tests

    func testSingleEmbeddingDimension() async throws {
        let embedding = try await service.embed("Apple announces new iPhone")
        XCTAssertEqual(embedding.count, NomicEmbeddingService.embeddingDimension,
                       "Embedding should be \(NomicEmbeddingService.embeddingDimension) dimensions")
    }

    func testBatchEmbeddingDimensions() async throws {
        let texts = ["Apple", "Google", "Microsoft"]
        let embeddings = try await service.embed(texts)
        XCTAssertEqual(embeddings.count, 3, "Should return 3 embeddings")
        for (i, emb) in embeddings.enumerated() {
            XCTAssertEqual(emb.count, NomicEmbeddingService.embeddingDimension,
                           "Embedding \(i) should be \(NomicEmbeddingService.embeddingDimension) dimensions")
        }
    }

    func testBatchMatchesSequential() async throws {
        let texts = ["Apple launches Vision Pro", "Google releases Gemini", "Tesla cuts prices"]

        // Get batch results
        let batchResults = try await service.embed(texts)

        // Get sequential results
        var sequentialResults: [[Float]] = []
        for text in texts {
            let emb = try await service.embed(text)
            sequentialResults.append(emb)
        }

        XCTAssertEqual(batchResults.count, sequentialResults.count)

        // Batch and sequential should produce very similar results.
        // They won't be bit-identical due to padding/attention mask differences,
        // but cosine similarity should be > 0.99.
        for i in 0..<texts.count {
            let similarity = cosineSimilarity(batchResults[i], sequentialResults[i])
            XCTAssertGreaterThan(similarity, 0.99,
                                 "Batch vs sequential similarity for '\(texts[i])' should be > 0.99, got \(similarity)")
        }
    }

    func testBatchEmbeddingsAreDistinct() async throws {
        let texts = ["Artificial intelligence", "Chocolate cake recipe", "Quantum physics research"]
        let embeddings = try await service.embed(texts)

        // Each embedding should be meaningfully different from the others
        for i in 0..<embeddings.count {
            for j in (i + 1)..<embeddings.count {
                let similarity = cosineSimilarity(embeddings[i], embeddings[j])
                XCTAssertLessThan(similarity, 0.95,
                                  "Embeddings for '\(texts[i])' and '\(texts[j])' should be distinct (sim=\(similarity))")
            }
        }
    }

    func testLargeBatchSplitsCorrectly() async throws {
        // 40 texts should be split into 2 sub-batches (maxBatchSize=32)
        let texts = (0..<40).map { "Entity number \($0) in the knowledge graph" }
        let embeddings = try await service.embed(texts)
        XCTAssertEqual(embeddings.count, 40, "Should return 40 embeddings")
        for emb in embeddings {
            XCTAssertEqual(emb.count, NomicEmbeddingService.embeddingDimension)
        }
    }

    // MARK: - Helpers

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }
}
