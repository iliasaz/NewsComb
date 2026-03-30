import XCTest
import GRDB
@testable import NewsCombApp

/// Tests that resetKnowledgeGraph and clearAllArticles work when
/// social_agent rows reference hypergraph_node (NO ACTION FK in existing DBs).
final class ResetKnowledgeGraphTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUp() {
        super.setUp()
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try! DatabaseQueue(configuration: config)
        try! dbQueue.write { db in
            try createSchema(db)
        }
    }

    override func tearDown() {
        dbQueue = nil
        super.tearDown()
    }

    func testDeleteHypergraphNodeBlockedBySocialAgent() throws {
        // Reproduces the exact error: social_agent.node_id → hypergraph_node(id)
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label) VALUES (1, 'n1', 'Apple')")
            try db.execute(sql: "INSERT INTO social_simulation (id, name) VALUES ('sim1', 'Test Sim')")
            try db.execute(sql: """
                INSERT INTO social_agent (id, node_id, display_name, simulation_id, oasis_user_id)
                VALUES (1, 1, 'Apple Agent', 'sim1', 0)
            """)
        }

        // Without deleting social_agent first, this should fail
        XCTAssertThrowsError(try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM hypergraph_node")
        }, "Should fail due to FK from social_agent")

        // Fix: delete social_agent before nodes
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM social_agent")
            try db.execute(sql: "DELETE FROM hypergraph_node")
        }

        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node")!
        }
        XCTAssertEqual(count, 0)
    }

    func testClearAllArticlesWithSocialAgentReferences() throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO rss_source (id, url) VALUES (1, 'https://test.com/feed')")
            try db.execute(sql: "INSERT INTO feed_item (id, source_id, guid, title, link) VALUES (10, 1, 'g1', 'T1', 'https://a.com')")
            try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label) VALUES (1, 'n1', 'Apple')")
            try db.execute(sql: "INSERT INTO hypergraph_edge (id, edge_id, label) VALUES (1, 'e1', 'launches')")
            try db.execute(sql: "INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES (1, 1, 'source', 0)")
            try db.execute(sql: "INSERT INTO social_simulation (id, name) VALUES ('sim1', 'Test Sim')")
            try db.execute(sql: """
                INSERT INTO social_agent (id, node_id, display_name, simulation_id, oasis_user_id)
                VALUES (1, 1, 'Apple Agent', 'sim1', 0)
            """)
        }

        // Simulate clearAllArticles: delete social agents before nodes
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM social_agent")
            try db.execute(sql: "DELETE FROM hypergraph_incidence")
            try db.execute(sql: "DELETE FROM hypergraph_edge")
            try db.execute(sql: "DELETE FROM hypergraph_node")
            try db.execute(sql: "DELETE FROM feed_item")
        }

        let nodeCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node")!
        }
        XCTAssertEqual(nodeCount, 0)

        // social_agent is also cleared (it references the deleted nodes)
        let agentCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM social_agent")!
        }
        XCTAssertEqual(agentCount, 0)
    }

    func testResetKnowledgeGraphWithNodeMergeHistory() throws {
        try dbQueue.write { db in
            try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label) VALUES (1, 'n1', 'Apple')")
            try db.execute(sql: """
                INSERT INTO node_merge_history (kept_node_id, removed_node_id, removed_node_label, similarity_score)
                VALUES (1, 999, 'AAPL', 0.95)
            """)
        }

        // With defer, deleting node_merge_history then hypergraph_node works
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            try db.execute(sql: "DELETE FROM node_merge_history")
            try db.execute(sql: "DELETE FROM hypergraph_node")
        }

        let count = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node")!
        }
        XCTAssertEqual(count, 0)
    }

    // MARK: - Schema

    private func createSchema(_ db: GRDB.Database) throws {
        // Minimal schema matching the real DB's FK structure (NO ACTION, not CASCADE)
        try db.execute(sql: """
            CREATE TABLE rss_source (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE feed_item (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id INTEGER NOT NULL REFERENCES rss_source(id),
                guid TEXT NOT NULL,
                title TEXT NOT NULL,
                link TEXT NOT NULL,
                UNIQUE(source_id, guid)
            );
            CREATE TABLE hypergraph_node (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL
            );
            CREATE TABLE hypergraph_edge (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                edge_id TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                source_chunk_id INTEGER REFERENCES article_chunk(id),
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE hypergraph_incidence (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                edge_id INTEGER NOT NULL REFERENCES hypergraph_edge(id),
                node_id INTEGER NOT NULL REFERENCES hypergraph_node(id),
                role TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                UNIQUE(edge_id, node_id, role)
            );
            CREATE TABLE article_chunk (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id),
                chunk_index INTEGER NOT NULL,
                content TEXT NOT NULL,
                UNIQUE(feed_item_id, chunk_index)
            );
            CREATE TABLE node_merge_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                merged_at REAL NOT NULL DEFAULT (unixepoch()),
                kept_node_id INTEGER NOT NULL REFERENCES hypergraph_node(id),
                removed_node_id INTEGER NOT NULL,
                removed_node_label TEXT NOT NULL,
                similarity_score REAL NOT NULL
            );
            CREATE TABLE social_simulation (
                id TEXT PRIMARY KEY,
                name TEXT NOT NULL,
                status TEXT NOT NULL DEFAULT 'configuring',
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE social_agent (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id INTEGER NOT NULL REFERENCES hypergraph_node(id),
                display_name TEXT NOT NULL,
                bio TEXT,
                persona_json TEXT,
                simulation_id TEXT NOT NULL REFERENCES social_simulation(id),
                oasis_user_id INTEGER NOT NULL
            );
        """)
    }
}
