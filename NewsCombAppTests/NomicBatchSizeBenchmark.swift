import XCTest
@testable import NewsCombApp

/// Benchmarks different batch sizes for Nomic embedding on the current GPU.
/// Run this test to find the optimal batch size for your hardware.
///
/// Prints a table of batch size → throughput (embeddings/sec).
@MainActor
final class NomicBatchSizeBenchmark: XCTestCase {

    func testBatchSizeThroughput() async throws {
        let service = NomicEmbeddingService.shared

        // Warm up the model (first call downloads/loads it)
        _ = try await service.embed("warmup")

        // Generate realistic test texts (varied lengths like real entity names)
        let texts: [String] = (0..<128).map { i in
            switch i % 4 {
            case 0: return "Apple Inc."
            case 1: return "Artificial intelligence and machine learning research"
            case 2: return "The European Union's General Data Protection Regulation"
            default: return "CEO Tim Cook announces new product lineup at WWDC conference"
            }
        }

        let batchSizes = [1, 4, 8, 16, 32, 48, 64, 96, 128]
        var results: [(batchSize: Int, throughput: Double)] = []

        print("\n========== Nomic Embedding Batch Size Benchmark ==========")
        print("Batch Size    Time (64 emb)   Throughput")
        print(String(repeating: "-", count: 44))

        for batchSize in batchSizes {
            let testTexts = Array(texts.prefix(64))
            let start = ContinuousClock.now

            // Process 64 texts in sub-batches of the candidate size
            var allEmbeddings: [[Float]] = []
            for batchStart in stride(from: 0, to: testTexts.count, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, testTexts.count)
                let batch = Array(testTexts[batchStart..<batchEnd])
                let embs = try await service.embed(batch)
                allEmbeddings.append(contentsOf: embs)
            }

            let elapsed = ContinuousClock.now - start
            let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let throughput = Double(allEmbeddings.count) / seconds

            results.append((batchSize, throughput))
            let timeStr = seconds.formatted(.number.precision(.fractionLength(2)))
            let tpStr = Int(throughput)
            print("\(batchSize)\t\t\(timeStr)s\t\t\(tpStr) emb/s")
        }

        print(String(repeating: "-", count: 44))

        if let best = results.max(by: { $0.throughput < $1.throughput }) {
            print(">>> Optimal batch size: \(best.batchSize) (\(Int(best.throughput)) emb/s)")
        }

        print("==========================================================\n")
    }
}
