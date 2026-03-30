import XCTest
import GRDB
@testable import NewsCombApp

/// Tests that GRDB allows `PRAGMA defer_foreign_keys` inside a write block,
/// and that the cascade delete logic works end-to-end through GRDB's API
/// (not just raw SQLite).
final class DeleteSourceGRDBTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUp() {
        super.setUp()
        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try! DatabaseQueue(configuration: config)
        try! dbQueue.write { db in
            try createSchema(db)
            try insertTestData(db)
        }
    }

    override func tearDown() {
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testDeferForeignKeysWorksInGRDBWriteBlock() throws {
        // Verify the pragma actually takes effect inside a GRDB write block
        try dbQueue.write { db in
            // This should NOT throw — defer_foreign_keys is allowed mid-transaction
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            let value = try Int.fetchOne(db, sql: "PRAGMA defer_foreign_keys")
            XCTAssertEqual(value, 1, "defer_foreign_keys should be ON")
        }
    }

    func testForeignKeysOffIsIgnoredInGRDBWriteBlock() throws {
        // Verify that PRAGMA foreign_keys = OFF is silently ignored mid-transaction
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            let value = try Int.fetchOne(db, sql: "PRAGMA foreign_keys")
            // Should still be ON because GRDB set it on connection open
            // and it can't be changed mid-transaction
            XCTAssertEqual(value, 1, "foreign_keys should still be ON (can't change mid-transaction)")
        }
    }

    func testDeleteSourceViaGRDB() throws {
        // Verify data exists
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item WHERE source_id = 1")!, 2)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_edge")!, 2)
        }

        // Delete using the same GRDB write block pattern as the app
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

            let sourceId: Int64 = 1

            let edgeIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM hypergraph_edge WHERE source_chunk_id IN
                (SELECT id FROM article_chunk WHERE feed_item_id IN
                 (SELECT id FROM feed_item WHERE source_id = ?))
                """, arguments: [sourceId])

            let chunkIds = try Int64.fetchAll(db, sql: """
                SELECT id FROM article_chunk WHERE feed_item_id IN
                (SELECT id FROM feed_item WHERE source_id = ?)
                """, arguments: [sourceId])

            // Delete edges and dependents
            for batch in edgeIds.chunked(into: 500) {
                let ph = batch.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(batch)
                try db.execute(sql: "DELETE FROM cluster_exemplars WHERE event_id IN (\(ph))", arguments: args)
                try db.execute(sql: "DELETE FROM cluster_members WHERE event_id IN (\(ph))", arguments: args)
                try db.execute(sql: "DELETE FROM event_cluster WHERE event_id IN (\(ph))", arguments: args)
                try db.execute(sql: "DELETE FROM article_edge_provenance WHERE edge_id IN (\(ph))", arguments: args)
                try db.execute(sql: "DELETE FROM hypergraph_incidence WHERE edge_id IN (\(ph))", arguments: args)
                try db.execute(sql: "DELETE FROM hypergraph_edge WHERE id IN (\(ph))", arguments: args)
            }

            // Delete chunks and dependents
            for batch in chunkIds.chunked(into: 500) {
                let ph = batch.map { _ in "?" }.joined(separator: ",")
                let args = StatementArguments(batch)
                try db.execute(sql: "DELETE FROM chunk_embedding_metadata WHERE chunk_id IN (\(ph))", arguments: args)
                try db.execute(sql: "DELETE FROM article_chunk WHERE id IN (\(ph))", arguments: args)
            }

            // Delete feed-item dependents
            try db.execute(sql: """
                DELETE FROM article_edge_provenance WHERE feed_item_id IN
                (SELECT id FROM feed_item WHERE source_id = ?)
                """, arguments: [sourceId])
            try db.execute(sql: """
                DELETE FROM article_hypergraph WHERE feed_item_id IN
                (SELECT id FROM feed_item WHERE source_id = ?)
                """, arguments: [sourceId])

            try db.execute(sql: "DELETE FROM feed_item WHERE source_id = ?", arguments: [sourceId])

            // This is what SettingsViewModel does — GRDB's delete on the model
            let source = try RSSSource.fetchOne(db, sql:
                "SELECT * FROM rss_source WHERE id = ?", arguments: [sourceId])
            if let source {
                _ = try source.delete(db)
            }
        }

        // Verify all gone
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source")!, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item")!, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_chunk")!, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_edge")!, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_incidence")!, 0)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_edge_provenance")!, 0)
        }
    }

    // MARK: - Schema & Data

    private func createSchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE rss_source (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                title TEXT,
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE feed_item (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                source_id INTEGER NOT NULL REFERENCES rss_source(id),
                guid TEXT NOT NULL,
                title TEXT NOT NULL,
                link TEXT NOT NULL,
                pub_date REAL,
                rss_description TEXT,
                full_content TEXT,
                author TEXT,
                fetched_at REAL NOT NULL DEFAULT (unixepoch()),
                UNIQUE(source_id, guid)
            );
            CREATE TABLE hypergraph_node (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL
            );
            CREATE TABLE article_chunk (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id),
                chunk_index INTEGER NOT NULL,
                content TEXT NOT NULL,
                UNIQUE(feed_item_id, chunk_index)
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
            CREATE TABLE article_hypergraph (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id),
                processing_status TEXT NOT NULL DEFAULT 'pending',
                UNIQUE(feed_item_id)
            );
            CREATE TABLE article_edge_provenance (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                edge_id INTEGER NOT NULL REFERENCES hypergraph_edge(id),
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id),
                chunk_index INTEGER,
                chunk_text TEXT,
                UNIQUE(edge_id, feed_item_id, chunk_index)
            );
            CREATE TABLE chunk_embedding_metadata (
                chunk_id INTEGER PRIMARY KEY REFERENCES article_chunk(id),
                computed_at REAL NOT NULL DEFAULT (unixepoch()),
                model_name TEXT
            );
            CREATE TABLE event_cluster (
                event_id INTEGER PRIMARY KEY,
                build_id TEXT NOT NULL,
                cluster_id INTEGER NOT NULL,
                membership REAL
            );
            CREATE TABLE clusters (
                cluster_id INTEGER NOT NULL,
                build_id TEXT NOT NULL,
                size INTEGER,
                PRIMARY KEY (cluster_id, build_id)
            );
            CREATE TABLE cluster_members (
                cluster_id INTEGER NOT NULL,
                event_id INTEGER NOT NULL,
                membership REAL,
                PRIMARY KEY (cluster_id, event_id)
            );
            CREATE TABLE cluster_exemplars (
                cluster_id INTEGER NOT NULL,
                event_id INTEGER NOT NULL,
                rank INTEGER NOT NULL,
                PRIMARY KEY (cluster_id, rank)
            );
        """)
    }

    private func insertTestData(_ db: GRDB.Database) throws {
        try db.execute(sql: "INSERT INTO rss_source (id, url) VALUES (1, 'https://example.com/feed')")
        try db.execute(sql: "INSERT INTO feed_item (id, source_id, guid, title, link) VALUES (10, 1, 'g1', 'T1', 'https://a.com')")
        try db.execute(sql: "INSERT INTO feed_item (id, source_id, guid, title, link) VALUES (11, 1, 'g2', 'T2', 'https://b.com')")
        try db.execute(sql: "INSERT INTO article_chunk (id, feed_item_id, chunk_index, content) VALUES (100, 10, 0, 'text1')")
        try db.execute(sql: "INSERT INTO article_chunk (id, feed_item_id, chunk_index, content) VALUES (101, 11, 0, 'text2')")
        try db.execute(sql: "INSERT INTO chunk_embedding_metadata (chunk_id) VALUES (100)")
        try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label) VALUES (200, 'n1', 'Apple')")
        try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label) VALUES (201, 'n2', 'Google')")
        try db.execute(sql: "INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id) VALUES (300, 'e1', 'acquires', 100)")
        try db.execute(sql: "INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id) VALUES (301, 'e2', 'partners', 101)")
        try db.execute(sql: "INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES (300, 200, 'source', 0)")
        try db.execute(sql: "INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES (300, 201, 'target', 0)")
        try db.execute(sql: "INSERT INTO article_hypergraph (feed_item_id, processing_status) VALUES (10, 'completed')")
        try db.execute(sql: "INSERT INTO article_edge_provenance (edge_id, feed_item_id, chunk_index) VALUES (300, 10, 0)")
        try db.execute(sql: "INSERT INTO event_cluster (event_id, build_id, cluster_id, membership) VALUES (300, 'b1', 1, 0.9)")
        try db.execute(sql: "INSERT INTO clusters (cluster_id, build_id, size) VALUES (1, 'b1', 1)")
        try db.execute(sql: "INSERT INTO cluster_members (cluster_id, event_id, membership) VALUES (1, 300, 0.9)")
        try db.execute(sql: "INSERT INTO cluster_exemplars (cluster_id, event_id, rank) VALUES (1, 300, 0)")
    }
}

private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
