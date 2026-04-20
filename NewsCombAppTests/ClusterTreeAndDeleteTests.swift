import XCTest
import GRDB
import MCP
@testable import NewsCombApp

/// Tests for the parent/child tree schema, save/discard/delete semantics,
/// and the new MCP tools' argument parsing.
final class ClusterTreeAndDeleteTests: XCTestCase {

    // MARK: - Schema migration round-trip

    func testParentAndTentativeColumnsRoundTrip() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE clusters (
                    cluster_id INTEGER PRIMARY KEY,
                    build_id TEXT NOT NULL,
                    label TEXT,
                    size INTEGER NOT NULL,
                    centroid_vec BLOB,
                    top_entities_json TEXT,
                    top_rel_families_json TEXT,
                    summary TEXT,
                    created_at REAL NOT NULL DEFAULT (unixepoch()),
                    parent_cluster_id INTEGER REFERENCES clusters(cluster_id) ON DELETE SET NULL,
                    is_tentative INTEGER NOT NULL DEFAULT 0
                )
            """)
            // Parent
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size) VALUES (1, 'b', 100)")
            // Saved child
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (2, 'b', 50, 1, 0)")
            // Tentative child
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (3, 'b', 30, 1, 1)")
        }

        try dbQueue.read { db in
            let parent = try Row.fetchOne(db, sql: "SELECT * FROM clusters WHERE cluster_id = 1")!
            let parentClusterId: Int64? = parent["parent_cluster_id"]
            let parentTentative: Int = parent["is_tentative"]
            XCTAssertNil(parentClusterId)
            XCTAssertEqual(parentTentative, 0)

            let savedChild = try Row.fetchOne(db, sql: "SELECT * FROM clusters WHERE cluster_id = 2")!
            XCTAssertEqual(savedChild["parent_cluster_id"] as Int64?, 1)
            XCTAssertEqual(savedChild["is_tentative"] as Int, 0)

            let tentChild = try Row.fetchOne(db, sql: "SELECT * FROM clusters WHERE cluster_id = 3")!
            XCTAssertEqual(tentChild["parent_cluster_id"] as Int64?, 1)
            XCTAssertEqual(tentChild["is_tentative"] as Int, 1)
        }
    }

    /// Regression test: deleting a parent must UNLINK tentative children too (not delete them).
    /// Tentative children should additionally have their is_tentative flag cleared so they
    /// become regular standalone themes.
    func testDeleteParentUnlinksTentativeChildrenAndPromotesThem() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
                CREATE TABLE clusters (
                    cluster_id INTEGER PRIMARY KEY,
                    build_id TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    parent_cluster_id INTEGER REFERENCES clusters(cluster_id) ON DELETE SET NULL,
                    is_tentative INTEGER NOT NULL DEFAULT 0
                )
            """)
            // Parent
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size) VALUES (1, 'b', 100)")
            // One saved + two tentative children
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (2, 'b', 50, 1, 0)")
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (3, 'b', 30, 1, 1)")
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (4, 'b', 20, 1, 1)")
        }

        // Replicate the service's delete logic: clear is_tentative on children first, then delete parent.
        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clusters SET is_tentative = 0 WHERE parent_cluster_id = ? AND is_tentative = 1",
                arguments: [1]
            )
            try db.execute(sql: "DELETE FROM clusters WHERE cluster_id = ?", arguments: [1])
        }

        try dbQueue.read { db in
            // All 3 children survive
            let ids = try Int64.fetchAll(db, sql: "SELECT cluster_id FROM clusters ORDER BY cluster_id")
            XCTAssertEqual(ids, [2, 3, 4])

            // All 3 children are unlinked (parent_cluster_id NULL)
            for id in [Int64(2), 3, 4] {
                let parent: Int64? = try Row.fetchOne(db, sql: "SELECT parent_cluster_id FROM clusters WHERE cluster_id = ?", arguments: [id])?["parent_cluster_id"]
                XCTAssertNil(parent, "Child #\(id) should be unlinked")
            }

            // No child should still be tentative
            let tentativeCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM clusters WHERE is_tentative = 1") ?? -1
            XCTAssertEqual(tentativeCount, 0, "All tentative children should have been promoted")
        }
    }

    func testFKOnDeleteSetNullUnlinksChildrenWhenParentDeleted() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
                CREATE TABLE clusters (
                    cluster_id INTEGER PRIMARY KEY,
                    build_id TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    parent_cluster_id INTEGER REFERENCES clusters(cluster_id) ON DELETE SET NULL,
                    is_tentative INTEGER NOT NULL DEFAULT 0
                )
            """)
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size) VALUES (1, 'b', 100)")
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id) VALUES (2, 'b', 50, 1)")
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id) VALUES (3, 'b', 30, 1)")
        }

        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM clusters WHERE cluster_id = 1")
        }

        try dbQueue.read { db in
            let row2 = try Row.fetchOne(db, sql: "SELECT parent_cluster_id FROM clusters WHERE cluster_id = 2")!
            let row3 = try Row.fetchOne(db, sql: "SELECT parent_cluster_id FROM clusters WHERE cluster_id = 3")!
            XCTAssertNil(row2["parent_cluster_id"] as Int64?, "Saved children should be unlinked, not deleted")
            XCTAssertNil(row3["parent_cluster_id"] as Int64?)
        }
    }

    // MARK: - Save/Discard semantics (pure SQL — verifies the queries we use in service)

    func testSaveSplitClearsTentativeFlag() throws {
        let dbQueue = try makeClustersDB()
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size) VALUES (1, 'b', 100)")
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (2, 'b', 50, 1, 1)")
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (3, 'b', 30, 1, 1)")
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "UPDATE clusters SET is_tentative = 0 WHERE parent_cluster_id = ? AND is_tentative = 1",
                arguments: [1]
            )
            XCTAssertEqual(db.changesCount, 2)
        }

        try dbQueue.read { db in
            let count = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM clusters WHERE parent_cluster_id = ? AND is_tentative = 0",
                arguments: [1]
            )
            XCTAssertEqual(count, 2)
        }
    }

    func testDiscardSplitRemovesOnlyTentativeChildren() throws {
        let dbQueue = try makeClustersDB()
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size) VALUES (1, 'b', 100)")
            // Mix of tentative and saved children
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (2, 'b', 50, 1, 1)")
            try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size, parent_cluster_id, is_tentative) VALUES (3, 'b', 30, 1, 0)")
        }

        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM clusters WHERE parent_cluster_id = ? AND is_tentative = 1",
                arguments: [1]
            )
        }

        try dbQueue.read { db in
            let remaining = try Int.fetchAll(db, sql: "SELECT cluster_id FROM clusters ORDER BY cluster_id")
            XCTAssertEqual(remaining, [1, 3], "Parent and saved child should remain; tentative removed")
        }
    }

    // MARK: - MCP tool argument parsing

    func testSaveSplitToolRequiresParentClusterId() async {
        let result = await MCPSaveSplitTool.run(arguments: [:])
        XCTAssertTrue(result.lowercased().contains("required"), result)
    }

    func testDiscardSplitToolRequiresParentClusterId() async {
        let result = await MCPDiscardSplitTool.run(arguments: [:])
        XCTAssertTrue(result.lowercased().contains("required"), result)
    }

    func testDeleteClusterToolRequiresClusterId() async {
        let result = await MCPDeleteClusterTool.run(arguments: [:])
        XCTAssertTrue(result.lowercased().contains("required"), result)
    }

    func testSaveSplitToolHandlesUnknownCluster() async {
        let result = await MCPSaveSplitTool.run(arguments: [
            "parent_cluster_id": .int(-9999),
            "wait": .bool(true),
        ])
        XCTAssertTrue(result.lowercased().contains("not found") || result.lowercased().contains("running"), result)
    }

    func testDeleteClusterToolHandlesUnknownCluster() async {
        let result = await MCPDeleteClusterTool.run(arguments: [
            "cluster_id": .int(-9999),
            "wait": .bool(true),
        ])
        XCTAssertTrue(result.lowercased().contains("not found") || result.lowercased().contains("running"), result)
    }

    // MARK: - Helpers

    private func makeClustersDB() throws -> DatabaseQueue {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try db.execute(sql: """
                CREATE TABLE clusters (
                    cluster_id INTEGER PRIMARY KEY,
                    build_id TEXT NOT NULL,
                    size INTEGER NOT NULL,
                    parent_cluster_id INTEGER REFERENCES clusters(cluster_id) ON DELETE SET NULL,
                    is_tentative INTEGER NOT NULL DEFAULT 0
                )
            """)
        }
        return dbQueue
    }
}
