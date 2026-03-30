import XCTest
import GRDB
@testable import NewsCombApp

/// Tests that deleting an RSS source cascades correctly through the full
/// dependency chain: rss_source → feed_item → article_chunk → hypergraph_edge
/// → hypergraph_incidence, event_vectors, cluster tables, etc.
final class DeleteSourceTests: XCTestCase {

    private var dbQueue: DatabaseQueue!

    override func setUp() {
        super.setUp()
        // Create an in-memory database with the same schema as the app
        dbQueue = try! DatabaseQueue()
        try! dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try createSchema(db)
        }
    }

    override func tearDown() {
        dbQueue = nil
        super.tearDown()
    }

    // MARK: - Tests

    func testDeleteSourceCascadesAllDependents() throws {
        // Set up a realistic dependency chain
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")

            // 1. RSS source
            try db.execute(sql: """
                INSERT INTO rss_source (id, url) VALUES (1, 'https://example.com/feed.xml')
            """)

            // 2. Feed items
            try db.execute(sql: """
                INSERT INTO feed_item (id, source_id, guid, title, link)
                VALUES (10, 1, 'guid1', 'Article 1', 'https://example.com/1')
            """)
            try db.execute(sql: """
                INSERT INTO feed_item (id, source_id, guid, title, link)
                VALUES (11, 1, 'guid2', 'Article 2', 'https://example.com/2')
            """)

            // 3. Article chunks
            try db.execute(sql: """
                INSERT INTO article_chunk (id, feed_item_id, chunk_index, content)
                VALUES (100, 10, 0, 'chunk text 1')
            """)
            try db.execute(sql: """
                INSERT INTO article_chunk (id, feed_item_id, chunk_index, content)
                VALUES (101, 10, 1, 'chunk text 2')
            """)
            try db.execute(sql: """
                INSERT INTO article_chunk (id, feed_item_id, chunk_index, content)
                VALUES (102, 11, 0, 'chunk text 3')
            """)

            // 4. Chunk embedding metadata
            try db.execute(sql: """
                INSERT INTO chunk_embedding_metadata (chunk_id) VALUES (100)
            """)
            try db.execute(sql: """
                INSERT INTO chunk_embedding_metadata (chunk_id) VALUES (101)
            """)

            // 5. Hypergraph nodes
            try db.execute(sql: """
                INSERT INTO hypergraph_node (id, node_id, label) VALUES (200, 'node_apple', 'Apple')
            """)
            try db.execute(sql: """
                INSERT INTO hypergraph_node (id, node_id, label) VALUES (201, 'node_google', 'Google')
            """)

            // 6. Hypergraph edges (with source_chunk_id FK to article_chunk)
            try db.execute(sql: """
                INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id)
                VALUES (300, 'edge_1', 'acquires', 100)
            """)
            try db.execute(sql: """
                INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id)
                VALUES (301, 'edge_2', 'partners with', 101)
            """)
            try db.execute(sql: """
                INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id)
                VALUES (302, 'edge_3', 'competes', 102)
            """)

            // 7. Hypergraph incidence
            try db.execute(sql: """
                INSERT INTO hypergraph_incidence (edge_id, node_id, role, position)
                VALUES (300, 200, 'source', 0)
            """)
            try db.execute(sql: """
                INSERT INTO hypergraph_incidence (edge_id, node_id, role, position)
                VALUES (300, 201, 'target', 0)
            """)

            // 8. Article hypergraph
            try db.execute(sql: """
                INSERT INTO article_hypergraph (feed_item_id, processing_status)
                VALUES (10, 'completed')
            """)

            // 9. Article edge provenance
            try db.execute(sql: """
                INSERT INTO article_edge_provenance (edge_id, feed_item_id, chunk_index)
                VALUES (300, 10, 0)
            """)

            // 10. Event cluster tables
            try db.execute(sql: """
                INSERT INTO event_cluster (event_id, build_id, cluster_id, membership)
                VALUES (300, 'build1', 1, 0.9)
            """)

            // 11. Clusters + members + exemplars
            try db.execute(sql: """
                INSERT INTO clusters (cluster_id, build_id, size) VALUES (1, 'build1', 3)
            """)
            try db.execute(sql: """
                INSERT INTO cluster_members (cluster_id, event_id, membership) VALUES (1, 300, 0.9)
            """)
            try db.execute(sql: """
                INSERT INTO cluster_exemplars (cluster_id, event_id, rank) VALUES (1, 300, 0)
            """)
        }

        // Verify setup
        let feedItemCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item WHERE source_id = 1")!
        }
        XCTAssertEqual(feedItemCount, 2)

        let edgeCount = try dbQueue.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_edge")!
        }
        XCTAssertEqual(edgeCount, 3)

        // Now delete source using the same logic as SettingsViewModel.deleteSource
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try deleteSourceCascade(db: db, sourceId: 1)
        }

        // Verify everything is gone
        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source")!, 0, "rss_source should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item")!, 0, "feed_item should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_chunk")!, 0, "article_chunk should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM chunk_embedding_metadata")!, 0, "chunk_embedding_metadata should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_hypergraph")!, 0, "article_hypergraph should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_edge_provenance")!, 0, "article_edge_provenance should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_incidence")!, 0, "hypergraph_incidence should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM event_cluster")!, 0, "event_cluster should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cluster_members")!, 0, "cluster_members should be empty")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM cluster_exemplars")!, 0, "cluster_exemplars should be empty")

            // Edges that referenced this source's chunks should be gone
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_edge")!, 0, "hypergraph_edge should be empty")

            // Nodes should remain (they're shared across sources)
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM hypergraph_node")!, 2, "hypergraph_node should be preserved")
        }
    }

    func testDeleteSourcePreservesOtherSources() throws {
        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")

            // Source 1 (will be deleted)
            try db.execute(sql: "INSERT INTO rss_source (id, url) VALUES (1, 'https://delete-me.com/feed')")
            try db.execute(sql: "INSERT INTO feed_item (id, source_id, guid, title, link) VALUES (10, 1, 'g1', 'T1', 'https://a.com/1')")

            // Source 2 (should survive)
            try db.execute(sql: "INSERT INTO rss_source (id, url) VALUES (2, 'https://keep-me.com/feed')")
            try db.execute(sql: "INSERT INTO feed_item (id, source_id, guid, title, link) VALUES (20, 2, 'g2', 'T2', 'https://b.com/1')")
            try db.execute(sql: "INSERT INTO article_chunk (id, feed_item_id, chunk_index, content) VALUES (200, 20, 0, 'keep this')")
        }

        try dbQueue.write { db in
            try db.execute(sql: "PRAGMA foreign_keys = ON")
            try deleteSourceCascade(db: db, sourceId: 1)
        }

        try dbQueue.read { db in
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source")!, 1, "Source 2 should survive")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item")!, 1, "Source 2's feed items should survive")
            XCTAssertEqual(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM article_chunk")!, 1, "Source 2's chunks should survive")
        }
    }

    // MARK: - The actual delete logic (extracted for testability)

    /// Deletes an RSS source and all dependent data in the correct order.
    ///
    /// Uses `PRAGMA defer_foreign_keys = ON` so FK checks are deferred to
    /// transaction commit, allowing deletes in any order within the transaction.
    private func deleteSourceCascade(db: GRDB.Database, sourceId: Int64) throws {
        // Defer FK checks to commit — this DOES work mid-transaction
        // (unlike PRAGMA foreign_keys which is silently ignored mid-transaction).
        try db.execute(sql: "PRAGMA defer_foreign_keys = ON")

        // Collect IDs for scoped deletes
        let feedItemIds = try Int64.fetchAll(db, sql:
            "SELECT id FROM feed_item WHERE source_id = ?", arguments: [sourceId])
        guard !feedItemIds.isEmpty else {
            try db.execute(sql: "DELETE FROM rss_source WHERE id = ?", arguments: [sourceId])
            return
        }

        let chunkIds = try Int64.fetchAll(db, sql: """
            SELECT id FROM article_chunk WHERE feed_item_id IN
            (SELECT id FROM feed_item WHERE source_id = ?)
            """, arguments: [sourceId])

        let edgeIds = try Int64.fetchAll(db, sql: """
            SELECT id FROM hypergraph_edge WHERE source_chunk_id IN
            (SELECT id FROM article_chunk WHERE feed_item_id IN
             (SELECT id FROM feed_item WHERE source_id = ?))
            """, arguments: [sourceId])

        // Delete edges and their dependents
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

        // Delete chunks and their dependents
        for batch in chunkIds.chunked(into: 500) {
            let ph = batch.map { _ in "?" }.joined(separator: ",")
            let args = StatementArguments(batch)
            try db.execute(sql: "DELETE FROM chunk_embedding_metadata WHERE chunk_id IN (\(ph))", arguments: args)
            try db.execute(sql: "DELETE FROM article_chunk WHERE id IN (\(ph))", arguments: args)
        }

        // Delete feed-item-level dependents
        try db.execute(sql: """
            DELETE FROM article_edge_provenance WHERE feed_item_id IN
            (SELECT id FROM feed_item WHERE source_id = ?)
            """, arguments: [sourceId])
        try db.execute(sql: """
            DELETE FROM article_hypergraph WHERE feed_item_id IN
            (SELECT id FROM feed_item WHERE source_id = ?)
            """, arguments: [sourceId])

        // Delete feed items and the source itself
        try db.execute(sql: "DELETE FROM feed_item WHERE source_id = ?", arguments: [sourceId])
        try db.execute(sql: "DELETE FROM rss_source WHERE id = ?", arguments: [sourceId])
    }

    // MARK: - Schema

    /// Creates the same schema as DatabaseService.migrate() for testing.
    private func createSchema(_ db: GRDB.Database) throws {
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
                pub_date REAL,
                fetched_at REAL NOT NULL DEFAULT (unixepoch()),
                UNIQUE(source_id, guid)
            );

            CREATE TABLE hypergraph_node (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                node_type TEXT
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

            CREATE TABLE article_chunk (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id),
                chunk_index INTEGER NOT NULL,
                content TEXT NOT NULL,
                UNIQUE(feed_item_id, chunk_index)
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
                label TEXT,
                centroid_vec BLOB,
                top_entities_json TEXT,
                top_rel_families_json TEXT,
                summary TEXT,
                created_at REAL NOT NULL DEFAULT (unixepoch()),
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
}

// Reuse the existing chunked extension from the codebase
private extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
