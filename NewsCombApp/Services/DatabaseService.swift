import Foundation
import GRDB
import SQLiteExtensions

public final class Database: Sendable {
    public static let shared = Database()

    let dbQueue: DatabaseQueue

    private init() {
        do {

            // Initialize all SQLite extensions
            SQLiteExtensions.initialize_sqlite3_extensions()

            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDirectory = appSupport.appending(path: "NewsComb")

            try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)

            let dbPath = dbDirectory.appending(path: "newscomb.sqlite")
            print("database: \(dbPath)")
            dbQueue = try DatabaseQueue(path: dbPath.path)

            try migrate()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS rss_source (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url TEXT NOT NULL UNIQUE,
                    title TEXT,
                    created_at REAL NOT NULL DEFAULT (unixepoch())
                );

                CREATE TABLE IF NOT EXISTS feed_item (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id INTEGER NOT NULL REFERENCES rss_source(id) ON DELETE CASCADE,
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

                CREATE TABLE IF NOT EXISTS app_settings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    key TEXT NOT NULL UNIQUE,
                    value TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_feed_item_source ON feed_item(source_id);
                CREATE INDEX IF NOT EXISTS idx_feed_item_guid ON feed_item(guid);

                -- Hypergraph tables for knowledge extraction

                CREATE TABLE IF NOT EXISTS hypergraph_node (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    node_id TEXT NOT NULL UNIQUE,
                    label TEXT NOT NULL,
                    node_type TEXT,
                    first_seen_at REAL NOT NULL DEFAULT (unixepoch()),
                    metadata_json TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_hypergraph_node_id ON hypergraph_node(node_id);

                CREATE TABLE IF NOT EXISTS hypergraph_edge (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    edge_id TEXT NOT NULL UNIQUE,
                    relation TEXT NOT NULL,
                    created_at REAL NOT NULL DEFAULT (unixepoch()),
                    metadata_json TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_hypergraph_edge_id ON hypergraph_edge(edge_id);
                CREATE INDEX IF NOT EXISTS idx_hypergraph_edge_relation ON hypergraph_edge(relation);

                CREATE TABLE IF NOT EXISTS hypergraph_incidence (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    edge_id INTEGER NOT NULL REFERENCES hypergraph_edge(id) ON DELETE CASCADE,
                    node_id INTEGER NOT NULL REFERENCES hypergraph_node(id) ON DELETE CASCADE,
                    role TEXT NOT NULL,
                    position INTEGER NOT NULL DEFAULT 0,
                    UNIQUE(edge_id, node_id, role)
                );
                CREATE INDEX IF NOT EXISTS idx_hypergraph_incidence_edge ON hypergraph_incidence(edge_id);
                CREATE INDEX IF NOT EXISTS idx_hypergraph_incidence_node ON hypergraph_incidence(node_id);

                CREATE TABLE IF NOT EXISTS article_hypergraph (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    feed_item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                    processed_at REAL NOT NULL DEFAULT (unixepoch()),
                    processing_status TEXT NOT NULL DEFAULT 'pending',
                    error_message TEXT,
                    chunk_count INTEGER DEFAULT 0,
                    UNIQUE(feed_item_id)
                );
                CREATE INDEX IF NOT EXISTS idx_article_hypergraph_status ON article_hypergraph(processing_status);

                CREATE TABLE IF NOT EXISTS article_edge_provenance (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    edge_id INTEGER NOT NULL REFERENCES hypergraph_edge(id) ON DELETE CASCADE,
                    feed_item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                    chunk_index INTEGER,
                    chunk_text TEXT,
                    confidence REAL,
                    UNIQUE(edge_id, feed_item_id, chunk_index)
                );
                CREATE INDEX IF NOT EXISTS idx_article_edge_provenance_edge ON article_edge_provenance(edge_id);
                CREATE INDEX IF NOT EXISTS idx_article_edge_provenance_feed ON article_edge_provenance(feed_item_id);

                -- Node embeddings virtual table using sqlite-vec (768-dim vectors)
                CREATE VIRTUAL TABLE IF NOT EXISTS node_embedding USING vec0(
                    node_id INTEGER PRIMARY KEY,
                    embedding float[768]
                );
            """)
        }
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
}
