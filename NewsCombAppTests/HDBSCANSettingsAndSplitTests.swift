import XCTest
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the HDBSCAN settings constants, the cluster-split MCP tool argument parsing,
/// and the HDBSCAN parameter validation behavior under split-style overrides.
///
/// Note: full end-to-end integration of `ClusteringService.splitCluster` exercises the
/// vec0 virtual tables and the LLM labeling pipeline. Those paths are covered by the
/// manual verification plan; this file validates the unit-level behaviors that can be
/// tested without standing up the entire schema.
final class HDBSCANSettingsAndSplitTests: XCTestCase {

    // MARK: - AppSettings constants

    func testHDBSCANSettingsKeysAreUnique() {
        let keys: Set<String> = [
            AppSettings.hdbscanMinClusterSize,
            AppSettings.hdbscanMinSamples,
            AppSettings.clusterMergeThreshold,
        ]
        XCTAssertEqual(keys.count, 3, "Each HDBSCAN setting key must be unique")
    }

    func testHDBSCANDefaults() {
        XCTAssertEqual(AppSettings.defaultHDBSCANMinClusterSize, 0,
                       "0 means auto — caller falls back to the in-code default")
        XCTAssertEqual(AppSettings.defaultHDBSCANMinSamples, 10)
        XCTAssertEqual(AppSettings.defaultClusterMergeThreshold, 0.85,
                       "Matches the previously hardcoded threshold in mergeSimilarClusters")
    }

    func testHDBSCANSettingsRoundTripThroughInMemoryDB() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE app_settings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    key TEXT NOT NULL UNIQUE,
                    value TEXT NOT NULL
                )
            """)
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "INSERT INTO app_settings (key, value) VALUES (?, ?)",
                arguments: [AppSettings.hdbscanMinClusterSize, "100"]
            )
            try db.execute(
                sql: "INSERT INTO app_settings (key, value) VALUES (?, ?)",
                arguments: [AppSettings.hdbscanMinSamples, "15"]
            )
            try db.execute(
                sql: "INSERT INTO app_settings (key, value) VALUES (?, ?)",
                arguments: [AppSettings.clusterMergeThreshold, "0.78"]
            )
        }

        try dbQueue.read { db in
            let s1 = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.hdbscanMinClusterSize)
                .fetchOne(db)
            XCTAssertEqual(Int(s1?.value ?? ""), 100)

            let s2 = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.hdbscanMinSamples)
                .fetchOne(db)
            XCTAssertEqual(Int(s2?.value ?? ""), 15)

            let s3 = try AppSettings
                .filter(AppSettings.Columns.key == AppSettings.clusterMergeThreshold)
                .fetchOne(db)
            XCTAssertEqual(Float(s3?.value ?? ""), 0.78)
        }
    }

    // MARK: - HDBSCAN.Parameters.validated under split-style overrides

    func testValidatedFloorAppliesEvenWhenUserPicksTinyMinClusterSize() {
        // User sets minClusterSize = 2 (pathological); validated() must clamp it.
        let params = HDBSCANService.Parameters(minClusterSize: 2, minSamples: 2)
        let validated = params.validated(forDataSize: 10_000)
        XCTAssertGreaterThanOrEqual(validated.minClusterSize, 20,
                                    "Floor of 20 prevents micro-clusters")
    }

    func testValidatedScalesMinClusterSizeWithSqrt() {
        // For N=10_000 the sqrt heuristic produces sqrt(10000)/2 = 50.
        let params = HDBSCANService.Parameters(minClusterSize: 20, minSamples: 10)
        let validated = params.validated(forDataSize: 10_000)
        XCTAssertGreaterThanOrEqual(validated.minClusterSize, 50)
    }

    func testValidatedClampsMinSamplesToMinClusterSize() {
        // minSamples must never exceed minClusterSize.
        let params = HDBSCANService.Parameters(minClusterSize: 25, minSamples: 50)
        let validated = params.validated(forDataSize: 1_000)
        XCTAssertLessThanOrEqual(validated.minSamples, validated.minClusterSize,
                                 "minSamples cannot exceed minClusterSize")
    }

    // MARK: - HDBSCAN behavior on a synthetic 4-blob dataset (split target)

    /// Simulates the kind of input a split would feed to HDBSCAN: a set of vectors
    /// that can plausibly fragment into multiple clusters.
    func testHDBSCANSplitsFourBlobsWhenAggressivelyParameterized() {
        var vectors: [[Float]] = []
        let centers: [(Float, Float)] = [(0, 0), (50, 0), (0, 50), (50, 50)]
        for (cx, cy) in centers {
            for i in 0..<20 {
                let jitter = Float(i) * 0.05
                vectors.append([cx + jitter, cy + jitter])
            }
        }

        let aggressive = HDBSCANService.Parameters(minClusterSize: 10, minSamples: 5, metric: .euclidean)
        let result = HDBSCANService().cluster(vectors: vectors, params: aggressive)
        XCTAssertGreaterThanOrEqual(result.clusterCount, 2,
                                    "Four well-separated blobs should produce at least 2 clusters at min=10")
    }

    // MARK: - MCPSplitClusterTool argument parsing

    func testSplitToolRequiresClusterId() async {
        let result = await MCPSplitClusterTool.run(arguments: [:])
        XCTAssertTrue(result.lowercased().contains("required"),
                      "Missing cluster_id must surface a clear error: \(result)")
    }

    func testSplitToolAcceptsAllOptionalArgs() async {
        // Cluster #-9999 is guaranteed not to exist; we're verifying the tool parses
        // arguments cleanly and forwards to the coordinator (which rejects unknown IDs).
        let args: [String: Value] = [
            "cluster_id": .int(-9999),
            "min_cluster_size": .int(50),
            "min_samples": .int(8),
            "relabel": .bool(false),
            "dry_run": .bool(true),
            "wait": .bool(true),
        ]
        let result = await MCPSplitClusterTool.run(arguments: args)
        // Coordinator should respond with a "not found" message (since #-9999 doesn't
        // exist) rather than a parsing error.
        XCTAssertFalse(result.lowercased().contains("required"),
                       "All args should parse without error; got: \(result)")
    }
}
