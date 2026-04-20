import XCTest
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the noise-pool outlier detector and the new MCP tools (identify_noise_pools,
/// drop_noise_pools, extract_theme). End-to-end extraction is exercised manually because it
/// depends on the vec0 chunk_embedding virtual table; this file covers everything that
/// can be tested in isolation.
final class NoisePoolAndExtractTests: XCTestCase {

    // MARK: - detectNoisePools — IQR rule on log(size)

    func testDetectsObviousGiantsOnSyntheticDistribution() {
        // Six small clusters + two clear giants. IQR on log sizes should flag both giants.
        let sizes: [(clusterId: Int64, size: Int)] = [
            (1, 10), (2, 12), (3, 15), (4, 20), (5, 25), (6, 30),
            (7, 5000), (8, 6000),
        ]
        let result = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: 1.5)
        XCTAssertEqual(Set(result.noisePoolClusterIds), Set([7, 8]),
                       "Both giants should be flagged at the standard 1.5x IQR rule")
        XCTAssertGreaterThan(result.logSizeThreshold, log(30),
                             "Threshold must sit above the small cluster sizes")
        XCTAssertLessThan(result.logSizeThreshold, log(5000),
                          "Threshold must sit below the giants")
    }

    func testNoOutliersOnUniformDistribution() {
        let sizes: [(clusterId: Int64, size: Int)] = [
            (1, 50), (2, 55), (3, 60), (4, 52), (5, 58),
        ]
        let result = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: 1.5)
        XCTAssertTrue(result.noisePoolClusterIds.isEmpty,
                      "No outliers when all sizes are similar")
    }

    func testIgnoresTinyClusters() {
        // The noise-1 events shouldn't compress the IQR.
        let sizes: [(clusterId: Int64, size: Int)] = [
            (1, 1), (2, 1), (3, 1), (4, 1),  // ignored (size <= 1)
            (5, 100), (6, 110), (7, 95), (8, 105), (9, 120),
        ]
        let result = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: 1.5)
        XCTAssertTrue(result.noisePoolClusterIds.isEmpty,
                      "Size-1 clusters are filtered before computing the IQR; the rest are uniform")
    }

    func testTooFewClustersReturnsEmpty() {
        let sizes: [(clusterId: Int64, size: Int)] = [(1, 10), (2, 20)]
        let result = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: 1.5)
        XCTAssertTrue(result.noisePoolClusterIds.isEmpty,
                      "Need at least 4 usable clusters to compute meaningful quartiles")
    }

    func testMultiplierTuningChangesFlagging() {
        let sizes: [(clusterId: Int64, size: Int)] = [
            (1, 10), (2, 12), (3, 15), (4, 20), (5, 25), (6, 30),
            (7, 200),  // borderline
        ]
        let lenient = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: 1.0)
        let strict = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: 3.0)
        XCTAssertGreaterThanOrEqual(lenient.noisePoolClusterIds.count, strict.noisePoolClusterIds.count,
                                    "A more lenient multiplier should never flag fewer clusters than a stricter one")
    }

    func testFlaggedIdsSortedBySizeDescending() {
        // Two giants among a uniform background. Verifies that flagged IDs are returned
        // largest-first. (Three giants would contaminate Q3 enough to mask the smaller
        // outlier under the 1.5x rule — that's a known property of unmodified IQR.)
        let sizes: [(clusterId: Int64, size: Int)] = [
            (1, 10), (2, 12), (3, 15), (4, 20), (5, 25), (6, 30),
            (7, 5000), (8, 9000),
        ]
        let result = ClusteringService.detectNoisePools(sizes: sizes, iqrMultiplier: 1.5)
        // Largest first: 8 (9000), 7 (5000)
        XCTAssertEqual(result.noisePoolClusterIds, [8, 7])
    }

    // MARK: - MCP tool argument parsing

    func testIdentifyNoisePoolsToolReturnsString() async {
        // Without a populated app, the tool should at minimum return a non-empty string
        // that doesn't crash. Real noise-pool detection is exercised by the unit tests above.
        let result = await MCPIdentifyNoisePoolsTool.run(arguments: [:])
        XCTAssertFalse(result.isEmpty)
    }

    func testDropNoisePoolsToolHandlesEmpty() async {
        let result = await MCPDropNoisePoolsTool.run(arguments: [:])
        // Either "No noise-pool clusters" or "operation already running" — both acceptable
        // depending on app state. Just verify no crash and a meaningful message.
        XCTAssertTrue(result.lowercased().contains("noise") || result.lowercased().contains("running"),
                      "Got: \(result)")
    }

    func testExtractThemeToolRequiresParentClusterId() async {
        let result = await MCPExtractThemeTool.run(arguments: [
            "query": .string("anything"),
        ])
        XCTAssertTrue(result.lowercased().contains("required"), result)
    }

    func testExtractThemeToolRequiresQuery() async {
        let result = await MCPExtractThemeTool.run(arguments: [
            "parent_cluster_id": .int(1),
        ])
        XCTAssertTrue(result.lowercased().contains("required"), result)
    }

    func testExtractThemeToolRejectsEmptyQuery() async {
        let result = await MCPExtractThemeTool.run(arguments: [
            "parent_cluster_id": .int(1),
            "query": .string("   "),
        ])
        XCTAssertTrue(result.lowercased().contains("required") || result.lowercased().contains("non-empty"), result)
    }

    func testExtractThemeToolHandlesUnknownCluster() async {
        let result = await MCPExtractThemeTool.run(arguments: [
            "parent_cluster_id": .int(-9999),
            "query": .string("Google Spanner BigQuery"),
            "wait": .bool(true),
        ])
        XCTAssertTrue(result.lowercased().contains("not found") || result.lowercased().contains("running"),
                      "Got: \(result)")
    }
}
