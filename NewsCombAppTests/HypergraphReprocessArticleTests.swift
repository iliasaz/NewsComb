import XCTest
import GRDB
@testable import NewsCombApp

/// Unit tests for the surgical delete chain that backs
/// `HypergraphService.reprocessArticle`. The full reprocess path also runs
/// `processArticle` (which needs an LLM provider), so we test the deletion
/// half in isolation here against an in-memory `DatabaseQueue` and
/// integration-test the LLM half elsewhere.
final class HypergraphReprocessArticleTests: XCTestCase {

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

    // MARK: - Happy path

    func testDeleteArticleGraphStateScopedToOneArticle() throws {
        try dbQueue.write { db in try seedTwoArticles(db) }

        let stats = try dbQueue.write { db in
            try HypergraphService.deleteArticleGraphState(db: db, feedItemId: 100)
        }

        // Article A had 2 chunks, 2 edges, 2 provenance rows. Node "shared"
        // and "only_b" remain alive because B still references them — only
        // "only_a" should have been swept.
        XCTAssertEqual(stats.chunksDeleted, 2)
        XCTAssertEqual(stats.edgesDeleted, 2)
        XCTAssertEqual(stats.provenanceDeleted, 2)
        XCTAssertEqual(stats.orphanNodesDeleted, 1)

        try dbQueue.read { db in
            XCTAssertEqual(try countAll(db, "article_chunk", "feed_item_id = 100"), 0)
            XCTAssertEqual(try countAll(db, "article_chunk", "feed_item_id = 200"), 1)

            XCTAssertEqual(try countAll(db, "hypergraph_edge", "id IN (1, 2)"), 0)
            XCTAssertEqual(try countAll(db, "hypergraph_edge", "id = 3"), 1)

            XCTAssertEqual(try countAll(db, "hypergraph_incidence", "edge_id IN (1, 2)"), 0)
            XCTAssertEqual(try countAll(db, "hypergraph_incidence", "edge_id = 3"), 2)

            XCTAssertEqual(try countAll(db, "article_edge_provenance", "feed_item_id = 100"), 0)
            XCTAssertEqual(try countAll(db, "article_edge_provenance", "feed_item_id = 200"), 1)

            XCTAssertEqual(try countAll(db, "article_hypergraph", "feed_item_id = 100"), 0)
            XCTAssertEqual(try countAll(db, "article_hypergraph", "feed_item_id = 200"), 1)
        }
    }

    // MARK: - Orphan boundary

    func testSharedNodeSurvivesWhenOtherArticleStillReferencesIt() throws {
        try dbQueue.write { db in try seedTwoArticles(db) }

        _ = try dbQueue.write { db in
            try HypergraphService.deleteArticleGraphState(db: db, feedItemId: 100)
        }

        try dbQueue.read { db in
            // "shared" node was used by both edges 1 (article A) and edge 3
            // (article B). After deleting A, it's still alive via edge 3.
            let sharedExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM hypergraph_node WHERE node_id = 'shared')"
            )
            XCTAssertEqual(sharedExists, true)

            // "only_b" must remain too: B's edge 3 still points at it.
            let onlyBExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM hypergraph_node WHERE node_id = 'only_b')"
            )
            XCTAssertEqual(onlyBExists, true)

            // "only_a" was used solely by edges 1 and 2; it must be gone.
            let onlyAExists = try Bool.fetchOne(
                db,
                sql: "SELECT EXISTS(SELECT 1 FROM hypergraph_node WHERE node_id = 'only_a')"
            )
            XCTAssertEqual(onlyAExists, false)
        }
    }

    // MARK: - No-op safety

    func testReprocessOnUnseenArticleIsNoOp() throws {
        try dbQueue.write { db in try seedTwoArticles(db) }

        // 999 has never been processed — no chunks, no edges, no provenance.
        let stats = try dbQueue.write { db in
            try HypergraphService.deleteArticleGraphState(db: db, feedItemId: 999)
        }

        XCTAssertEqual(stats.chunksDeleted, 0)
        XCTAssertEqual(stats.edgesDeleted, 0)
        XCTAssertEqual(stats.provenanceDeleted, 0)
        // Orphan sweep is global: any pre-existing orphans (none here) would count.
        XCTAssertEqual(stats.orphanNodesDeleted, 0)

        try dbQueue.read { db in
            // Article A and B are completely untouched.
            XCTAssertEqual(try countAll(db, "article_chunk", "feed_item_id = 100"), 2)
            XCTAssertEqual(try countAll(db, "article_chunk", "feed_item_id = 200"), 1)
            XCTAssertEqual(try countAll(db, "hypergraph_edge", "1 = 1"), 3)
            XCTAssertEqual(try countAll(db, "hypergraph_node", "1 = 1"), 3)
        }
    }

    // MARK: - Vec0 cleanup paths exercised

    func testEmbeddingRowsAreDeletedAlongsideTheirParents() throws {
        try dbQueue.write { db in
            try seedTwoArticles(db)
            // Seed embeddings for A's chunks and the soon-to-be-orphan "only_a" node.
            try db.execute(sql: "INSERT INTO chunk_embedding (chunk_id, embedding) VALUES (10, x'00')")
            try db.execute(sql: "INSERT INTO chunk_embedding (chunk_id, embedding) VALUES (11, x'00')")
            try db.execute(sql: "INSERT INTO chunk_embedding (chunk_id, embedding) VALUES (20, x'00')")
            try db.execute(sql: "INSERT INTO node_embedding (node_id, embedding) VALUES (1, x'00')")
            try db.execute(sql: "INSERT INTO node_embedding (node_id, embedding) VALUES (2, x'00')")
            try db.execute(sql: "INSERT INTO node_embedding (node_id, embedding) VALUES (3, x'00')")
            try db.execute(sql: "INSERT INTO event_vectors (event_id, vec) VALUES (1, x'00')")
            try db.execute(sql: "INSERT INTO event_vectors (event_id, vec) VALUES (2, x'00')")
            try db.execute(sql: "INSERT INTO event_vectors (event_id, vec) VALUES (3, x'00')")
            try db.execute(sql: "INSERT INTO event_cluster (event_id, build_id, cluster_id) VALUES (1, 'b', 1)")
            try db.execute(sql: "INSERT INTO event_cluster (event_id, build_id, cluster_id) VALUES (2, 'b', 1)")
            try db.execute(sql: "INSERT INTO event_cluster (event_id, build_id, cluster_id) VALUES (3, 'b', 2)")
        }

        _ = try dbQueue.write { db in
            try HypergraphService.deleteArticleGraphState(db: db, feedItemId: 100)
        }

        try dbQueue.read { db in
            // Chunk embeddings for A's chunks (10, 11) gone; B's (20) survives.
            XCTAssertEqual(try countAll(db, "chunk_embedding", "chunk_id IN (10, 11)"), 0)
            XCTAssertEqual(try countAll(db, "chunk_embedding", "chunk_id = 20"), 1)

            // Only the orphan node's embedding got swept. Node IDs 2 (shared)
            // and 3 (only_b) remain; node 1 (only_a) and its embedding are gone.
            XCTAssertEqual(try countAll(db, "node_embedding", "node_id = 1"), 0)
            XCTAssertEqual(try countAll(db, "node_embedding", "node_id IN (2, 3)"), 2)

            // Event-vectors and cluster assignments for A's edges (1, 2) gone;
            // B's edge 3 keeps its rows.
            XCTAssertEqual(try countAll(db, "event_vectors", "event_id IN (1, 2)"), 0)
            XCTAssertEqual(try countAll(db, "event_vectors", "event_id = 3"), 1)
            XCTAssertEqual(try countAll(db, "event_cluster", "event_id IN (1, 2)"), 0)
            XCTAssertEqual(try countAll(db, "event_cluster", "event_id = 3"), 1)
        }
    }

    // MARK: - Helpers

    private func countAll(_ db: GRDB.Database, _ table: String, _ predicate: String) throws -> Int {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE \(predicate)") ?? -1
    }

    /// Seeds two articles into a freshly-created in-memory schema:
    ///
    ///   feed_item 100 (article A): chunks 10, 11; edges 1, 2; nodes "shared",
    ///   "only_a"; provenance for both edges.
    ///   feed_item 200 (article B): chunk 20; edge 3; nodes "shared", "only_b";
    ///   provenance for edge 3.
    ///
    /// Node IDs: 1 = "only_a", 2 = "shared", 3 = "only_b".
    private func seedTwoArticles(_ db: GRDB.Database) throws {
        try db.execute(sql: "INSERT INTO rss_source (id, url) VALUES (1, 'https://test.com/feed')")
        try db.execute(sql: """
            INSERT INTO feed_item (id, source_id, guid, title, link)
            VALUES (100, 1, 'a', 'Article A', 'https://a.com'),
                   (200, 1, 'b', 'Article B', 'https://b.com')
        """)

        try db.execute(sql: """
            INSERT INTO article_chunk (id, feed_item_id, chunk_index, content) VALUES
                (10, 100, 0, 'A chunk 0'),
                (11, 100, 1, 'A chunk 1'),
                (20, 200, 0, 'B chunk 0')
        """)

        try db.execute(sql: """
            INSERT INTO hypergraph_node (id, node_id, label) VALUES
                (1, 'only_a', 'Only A'),
                (2, 'shared', 'Shared'),
                (3, 'only_b', 'Only B')
        """)

        try db.execute(sql: """
            INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id) VALUES
                (1, 'e1', 'rel1', 10),
                (2, 'e2', 'rel2', 11),
                (3, 'e3', 'rel3', 20)
        """)

        // Edge 1 (A): only_a + shared. Edge 2 (A): only_a only.
        // Edge 3 (B): only_b + shared.
        try db.execute(sql: """
            INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES
                (1, 1, 'source', 0),
                (1, 2, 'target', 0),
                (2, 1, 'source', 0),
                (3, 3, 'source', 0),
                (3, 2, 'target', 0)
        """)

        try db.execute(sql: """
            INSERT INTO article_edge_provenance (edge_id, feed_item_id, chunk_index, chunk_text) VALUES
                (1, 100, 0, 'A chunk 0'),
                (2, 100, 1, 'A chunk 1'),
                (3, 200, 0, 'B chunk 0')
        """)

        try db.execute(sql: """
            INSERT INTO article_hypergraph (feed_item_id, processing_status, chunk_count) VALUES
                (100, 'completed', 2),
                (200, 'completed', 1)
        """)
    }

    /// Minimal subset of the production schema covering everything the
    /// reprocess delete chain touches. Vec0 virtual tables (`chunk_embedding`,
    /// `node_embedding`, `event_vectors`) are stubbed as plain tables — same
    /// names and column shapes — so the DELETE statements compile and run
    /// without needing the sqlite-vec extension loaded in tests.
    private func createSchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE rss_source (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE
            );
            CREATE TABLE feed_item (
                id INTEGER PRIMARY KEY,
                source_id INTEGER NOT NULL REFERENCES rss_source(id) ON DELETE CASCADE,
                guid TEXT NOT NULL,
                title TEXT NOT NULL,
                link TEXT NOT NULL,
                UNIQUE(source_id, guid)
            );
            CREATE TABLE hypergraph_node (
                id INTEGER PRIMARY KEY,
                node_id TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL
            );
            CREATE TABLE article_chunk (
                id INTEGER PRIMARY KEY,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                content TEXT NOT NULL,
                UNIQUE(feed_item_id, chunk_index)
            );
            CREATE TABLE hypergraph_edge (
                id INTEGER PRIMARY KEY,
                edge_id TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                source_chunk_id INTEGER REFERENCES article_chunk(id)
            );
            CREATE TABLE hypergraph_incidence (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                edge_id INTEGER NOT NULL REFERENCES hypergraph_edge(id) ON DELETE CASCADE,
                node_id INTEGER NOT NULL REFERENCES hypergraph_node(id) ON DELETE CASCADE,
                role TEXT NOT NULL,
                position INTEGER NOT NULL DEFAULT 0,
                UNIQUE(edge_id, node_id, role)
            );
            CREATE TABLE article_hypergraph (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                processing_status TEXT NOT NULL,
                chunk_count INTEGER NOT NULL DEFAULT 0,
                UNIQUE(feed_item_id)
            );
            CREATE TABLE article_edge_provenance (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                edge_id INTEGER NOT NULL REFERENCES hypergraph_edge(id) ON DELETE CASCADE,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                chunk_index INTEGER NOT NULL,
                chunk_text TEXT,
                UNIQUE(edge_id, feed_item_id, chunk_index)
            );
            CREATE TABLE chunk_embedding (
                chunk_id INTEGER PRIMARY KEY,
                embedding BLOB
            );
            CREATE TABLE node_embedding (
                node_id INTEGER PRIMARY KEY,
                embedding BLOB
            );
            CREATE TABLE event_vectors (
                event_id INTEGER PRIMARY KEY,
                vec BLOB
            );
            CREATE TABLE event_cluster (
                event_id INTEGER PRIMARY KEY,
                build_id TEXT NOT NULL,
                cluster_id INTEGER NOT NULL,
                membership REAL NOT NULL DEFAULT 1.0
            );
        """)
    }
}
