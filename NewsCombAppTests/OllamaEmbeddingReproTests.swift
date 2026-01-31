import HyperGraphReasoning
import XCTest
@testable import NewsCombApp

// Disambiguate AccelerateVectorOps — both HyperGraphReasoning and NewsCombApp define it.
// The module name "NewsCombApp" collides with the @main struct, so we alias via
// HyperGraphReasoning (same implementation).
private typealias VectorOps = HyperGraphReasoning.AccelerateVectorOps

/// Integration tests to reproduce and detect the Ollama degenerate embedding issue.
///
/// On 2026-01-29 20:51–20:54, ~20 articles were batch-processed. The Ollama
/// embedding service returned near-identical 768-dim vectors for ~600 unrelated
/// entity names. When `NodeMergingService.simplifyHypergraph()` ran 19 minutes
/// later, it found 601 pairs with cosine similarity ≈ 1.0 and merged them all —
/// collapsing nodes like "Google DeepMind", "Claude Code", "Waymo AV", and
/// "Kidney transplant" into a single "EmulatorJS" node.
///
/// These tests send the exact same entity names through the same batch embedding
/// code path used by the app, then verify the returned embeddings are genuinely
/// distinct. They also test concurrent batches to simulate parallel article
/// processing.
///
/// **Requires:** Ollama running locally with `nomic-embed-text:v1.5` pulled.
@MainActor
final class OllamaEmbeddingReproTests: XCTestCase {

    /// Same batch size used by `EmbeddingService` in the app pipeline.
    static let batchSize = 100

    /// The embedding model used in the app.
    static let embeddingModel = "nomic-embed-text:v1.5"

    /// Expected dimensionality for nomic-embed-text:v1.5.
    static let expectedDimension = 768

    /// Similarity above which two *unrelated* entities should never score.
    /// Legitimate near-duplicates ("DeepSeek R1" / "DeepSeek-R1") might reach
    /// ~0.92, but completely unrelated entities like "EmulatorJS" and "Waymo AV"
    /// should be well below this.
    static let suspiciousThreshold: Float = 0.95

    private var ollamaService: OllamaService!

    // MARK: - Test Data

    /// Actual entity names extracted from `node_merge_history` — the exact labels
    /// that were spuriously merged with similarity ≈ 1.0 on 2026-01-29.
    /// They span all 20 articles processed in that batch.
    static let affectedEntityNames: [String] = [
        // "My Mom and Dr. DeepSeek"
        "Dr. Tian Jishun", "Dr. Melanie Hoenig", "Zhang Chao", "Jack Ma",
        "DeepSeek R1", "Baichuan AI", "Wei Lijia", "Real Kuang",
        "Wang Xiaochuan", "Shreya Johri", "Zhang Jiansheng", "Andrew Bean",
        "Lu Tang", "Synyi AI", "Influencers on WeChat", "MRI scans",

        // "Flameshot"
        "Qt Creator", "Prt Sc", "Mouse Wheel", "Desktop Environment",
        "System Settings", "Custom Shortcuts", "Keyboard Shortcuts",
        "Screenshot History", "Prebuilt Packages", "Right Click",
        "Flameshot GUI", "Plasma Wayland", "Gnome Wayland",
        "Microsoft Windows", "Open Anyway",

        // "MakuluLinux Backdoor"
        "C2 Server", "Contabo GmbH", "C2 Backdoor", "Contabo VPS",
        "Coalfire Labs", "Raw JSON", "Tenuo Warrants",

        // "Europe's weather satellite"
        "Infrared Sounder", "OHB Systems", "Middle East", "Sahara Desert",
        "Simonetta Cheli", "Second Imager", "European Commission",

        // "CLI Colors"
        "Tango Dark", "Tango Light", "Solarized Dark", "Solarized Light",
        "Ethan Schoonover",

        // "Cloudflare / Moltbot"
        "Cloudflare Workers", "Browser Rendering", "Google Maps",
        "AI Search", "Cloudflare Access", "Agents SDK", "Puppeteer APIs",
        "Admin UI", "Cloudflare Containers", "AI Agents",

        // "AgentMail"
        "AWS SES", "Prompt Injection", "O365 GCC", "Mail Agent",
        "Subscription Billing", "Developer Platform", "Sandbox SDK",
        "OTEL SDK", "Universal SDKs", "AI Gateway", "Unified Billing",

        // "OTelBench" / "Waymo"
        "Claude Code", "Madhu Gottumukkala", "Waymo AV", "James Champion",

        // Various articles
        "Google DeepMind", "José Ralat", "Rodrigo Bravo", "Instagram Reels",
        "Project Genie", "SignPath Foundation", "Void Linux",

        // "EmulatorJS"
        "EmulatorJS", "Sega CD", "Mega Drive", "Game Gear", "Master System",
        "Atari Lynx", "PlayStation Portable", "Sega 32X", "Nintendo DS",
        "Virtual Boy", "Sega Saturn", "Game Boy", "Atari Jaguar",
        "Commodore PET", "Commodore Amiga", "Code Generator",

        // Other articles
        "Trey Harris", "LoongArch ISA", "Loongson 3A6000", "AMD GPU",
        "C++20 Modules", "Generative AI", "Sendmail 8", "Big 8",
        "Agile teams", "Luleå University of Technology",
        "Concordia University", "Valery Fabrikant", "Alexander Abian",
        "EA App", "Rockstar Launcher", "Joe Talmadge", "Xiaolin Li",
    ]

    // MARK: - Setup

    override func setUp() async throws {
        try await super.setUp()
        ollamaService = OllamaService(embeddingModel: Self.embeddingModel)

        // Verify Ollama is reachable and the model is available
        do {
            let probe = try await ollamaService.embed("connectivity probe", model: Self.embeddingModel)
            guard probe.count == Self.expectedDimension else {
                throw XCTSkip(
                    "nomic-embed-text:v1.5 returned \(probe.count)-dim vector "
                    + "(expected \(Self.expectedDimension)). Wrong model version?"
                )
            }
        } catch is XCTSkip {
            throw XCTSkip("Ollama is not running or nomic-embed-text:v1.5 is unavailable")
        } catch {
            throw XCTSkip("Ollama is not running or nomic-embed-text:v1.5 is unavailable: \(error)")
        }
    }

    override func tearDown() {
        ollamaService = nil
        super.tearDown()
    }

    // MARK: - Single Batch: Embedding Distinctness

    /// Sends one full batch (100 entities) and verifies every pair has
    /// cosine similarity below the suspicious threshold.
    func testSingleBatchEmbeddingsAreDistinct() async throws {
        let batch = Array(Self.affectedEntityNames.prefix(Self.batchSize))
        let embeddings = try await ollamaService.embed(batch, model: Self.embeddingModel)

        XCTAssertEqual(embeddings.count, batch.count,
                       "Should return one embedding per input text")

        for (i, emb) in embeddings.enumerated() {
            XCTAssertEqual(emb.count, Self.expectedDimension,
                           "Embedding for '\(batch[i])' has wrong dimension (\(emb.count))")
        }

        // Use the same VectorOps code path as NodeMergingService
        let suspiciousPairs = VectorOps.findSimilarPairs(
            embeddings: embeddings,
            threshold: Self.suspiciousThreshold
        )

        for pair in suspiciousPairs {
            XCTFail(
                "Suspiciously similar: '\(batch[pair.i])' ↔ '\(batch[pair.j])' "
                + "similarity=\(String(format: "%.6f", pair.similarity)) "
                + "(threshold: \(Self.suspiciousThreshold))"
            )
        }
    }

    // MARK: - Multi-Batch via EmbeddingService (App Code Path)

    /// Uses `EmbeddingService.generateEmbeddings(for:)` — the exact code path
    /// the app uses during article processing — with the same batch size.
    func testMultiBatchViaEmbeddingService() async throws {
        let embeddingService = EmbeddingService(
            ollamaService: ollamaService,
            model: Self.embeddingModel,
            batchSize: Self.batchSize
        )

        let allNames = Self.affectedEntityNames
        let embeddingsDict = try await embeddingService.generateEmbeddings(for: allNames)

        // Every input should have an embedding
        var missing: [String] = []
        for name in allNames {
            if embeddingsDict[name] == nil {
                missing.append(name)
            }
        }
        XCTAssertTrue(missing.isEmpty,
                      "Missing embeddings for \(missing.count) inputs: \(missing.prefix(5))")

        // Collect in order for matrix ops
        let orderedEmbeddings = allNames.compactMap { embeddingsDict[$0] }
        guard orderedEmbeddings.count == allNames.count else { return }

        // Verify dimensions
        for (i, emb) in orderedEmbeddings.enumerated() {
            XCTAssertEqual(emb.count, Self.expectedDimension,
                           "Embedding for '\(allNames[i])' has wrong dimension")
        }

        // Check for degenerate pairs across the entire set (spanning batch boundaries)
        let suspiciousPairs = VectorOps.findSimilarPairs(
            embeddings: orderedEmbeddings,
            threshold: Self.suspiciousThreshold
        )

        if !suspiciousPairs.isEmpty {
            let summary = suspiciousPairs.prefix(5).map { pair in
                "  '\(allNames[pair.i])' ↔ '\(allNames[pair.j])' (sim=\(String(format: "%.6f", pair.similarity)))"
            }.joined(separator: "\n")
            XCTFail(
                "\(suspiciousPairs.count) suspicious pairs (similarity > \(Self.suspiciousThreshold)):\n\(summary)"
            )
        }
    }

    // MARK: - Concurrent Batches (Parallel Article Processing)

    /// Sends two batches concurrently (as happens during parallel article processing)
    /// and verifies cross-batch embeddings are still distinct.
    func testConcurrentBatchesProduceDistinctEmbeddings() async throws {
        let midpoint = Self.affectedEntityNames.count / 2
        let batch1 = Array(Self.affectedEntityNames.prefix(midpoint))
        let batch2 = Array(Self.affectedEntityNames.suffix(from: midpoint))

        // Fire both batches concurrently — the same pattern as parallel article processing.
        // Capture the actor reference locally so child tasks can send it safely.
        let service = ollamaService!
        let model = Self.embeddingModel
        async let result1 = service.embed(batch1, model: model)
        async let result2 = service.embed(batch2, model: model)

        let (emb1, emb2) = try await (result1, result2)

        XCTAssertEqual(emb1.count, batch1.count, "Batch 1 count mismatch")
        XCTAssertEqual(emb2.count, batch2.count, "Batch 2 count mismatch")

        // Cross-batch similarity check
        let allNames = batch1 + batch2
        let allEmbeddings = emb1 + emb2

        let suspiciousPairs = VectorOps.findSimilarPairs(
            embeddings: allEmbeddings,
            threshold: Self.suspiciousThreshold
        )

        for pair in suspiciousPairs {
            let crossBatch = (pair.i < midpoint) != (pair.j < midpoint)
            XCTFail(
                "\(crossBatch ? "CROSS-BATCH" : "INTRA-BATCH") suspicious: "
                + "'\(allNames[pair.i])' ↔ '\(allNames[pair.j])' "
                + "sim=\(String(format: "%.6f", pair.similarity))"
            )
        }
    }

    // MARK: - Degenerate Batch Detection

    /// Detects the specific failure mode: all embeddings in a batch are
    /// near-identical (cosine similarity > 0.999). This is the exact pattern
    /// that caused the mass merge.
    func testDetectDegenerateBatch() async throws {
        let batch = Array(Self.affectedEntityNames.prefix(Self.batchSize))
        let embeddings = try await ollamaService.embed(batch, model: Self.embeddingModel)

        guard embeddings.count >= 2 else {
            XCTFail("Need at least 2 embeddings to check for degeneracy")
            return
        }

        // Sample 20 random pairs and check for the degenerate pattern
        let sampleCount = 20
        var degenerateCount = 0
        var sampleSimilarities: [Float] = []

        for _ in 0..<sampleCount {
            let i = Int.random(in: 0..<embeddings.count)
            var j = Int.random(in: 0..<embeddings.count)
            while j == i { j = Int.random(in: 0..<embeddings.count) }

            let sim = VectorOps.cosineSimilarity(embeddings[i], embeddings[j])
            sampleSimilarities.append(sim)
            if sim > 0.999 {
                degenerateCount += 1
            }
        }

        let avgSim = sampleSimilarities.reduce(0, +) / Float(sampleSimilarities.count)
        let maxSim = sampleSimilarities.max() ?? 0

        // If more than 10% of random pairs are nearly identical, the batch is degenerate
        XCTAssertEqual(degenerateCount, 0,
                       "DEGENERATE BATCH DETECTED: \(degenerateCount)/\(sampleCount) random pairs "
                       + "have similarity > 0.999 (avg=\(String(format: "%.4f", avgSim)), "
                       + "max=\(String(format: "%.6f", maxSim))). "
                       + "The embedding model is returning identical vectors.")
    }

    // MARK: - Batch Determinism

    /// Sends the same entity names twice and verifies the embeddings match.
    /// This confirms the model is behaving deterministically when healthy.
    func testSameBatchProducesConsistentEmbeddings() async throws {
        let batch = Array(Self.affectedEntityNames.prefix(20))

        let emb1 = try await ollamaService.embed(batch, model: Self.embeddingModel)
        let emb2 = try await ollamaService.embed(batch, model: Self.embeddingModel)

        XCTAssertEqual(emb1.count, emb2.count, "Both calls should return the same count")

        for i in 0..<min(emb1.count, emb2.count) {
            let sim = VectorOps.cosineSimilarity(emb1[i], emb2[i])
            // Same input should produce the same output (similarity ≈ 1.0)
            XCTAssertGreaterThan(sim, 0.999,
                                 "Same input '\(batch[i])' produced different embeddings "
                                 + "across calls (similarity=\(String(format: "%.6f", sim)))")
        }
    }

    // MARK: - Embedding Norms

    /// Verifies that no embedding is a zero vector or has a degenerate norm.
    /// A zero-norm embedding would indicate the model failed silently.
    func testEmbeddingNormsAreReasonable() async throws {
        let batch = Array(Self.affectedEntityNames.prefix(50))
        let embeddings = try await ollamaService.embed(batch, model: Self.embeddingModel)

        for (i, emb) in embeddings.enumerated() {
            var normSq: Float = 0
            for val in emb { normSq += val * val }
            let norm = sqrt(normSq)

            XCTAssertGreaterThan(norm, 0.01,
                                 "Embedding for '\(batch[i])' has near-zero norm (\(norm))")
            // nomic-embed-text returns pre-normalized vectors (norm ≈ 1.0)
            XCTAssertEqual(norm, 1.0, accuracy: 0.01,
                           "Embedding for '\(batch[i])' is not unit-normalized (norm=\(norm))")
        }
    }
}
