import Foundation
import GRDB
import OSLog
import SQLiteExtensions

public final class Database: Sendable {
    private static let logger = Logger(subsystem: "com.newscomb", category: "Database")
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
            Self.logger.info("Database path: open '\(dbPath.path(percentEncoded: false), privacy: .public)'")
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

                -- Metadata for tracking computed embeddings (companion to virtual table)
                CREATE TABLE IF NOT EXISTS node_embedding_metadata (
                    node_id INTEGER PRIMARY KEY REFERENCES hypergraph_node(id) ON DELETE CASCADE,
                    computed_at REAL NOT NULL DEFAULT (unixepoch()),
                    model_name TEXT,
                    embedding_version INTEGER DEFAULT 1
                );

                -- History of node merges for tracking and potential undo
                CREATE TABLE IF NOT EXISTS node_merge_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    merged_at REAL NOT NULL DEFAULT (unixepoch()),
                    kept_node_id INTEGER NOT NULL REFERENCES hypergraph_node(id),
                    removed_node_id INTEGER NOT NULL,
                    removed_node_label TEXT NOT NULL,
                    similarity_score REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS idx_node_merge_history_kept ON node_merge_history(kept_node_id);

                -- Article chunks for fine-grained provenance tracking
                CREATE TABLE IF NOT EXISTS article_chunk (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    feed_item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                    chunk_index INTEGER NOT NULL,
                    content TEXT NOT NULL,
                    created_at REAL NOT NULL DEFAULT (unixepoch()),
                    UNIQUE(feed_item_id, chunk_index)
                );
                CREATE INDEX IF NOT EXISTS idx_article_chunk_feed ON article_chunk(feed_item_id);

                -- Chunk embeddings virtual table using sqlite-vec (768-dim vectors)
                CREATE VIRTUAL TABLE IF NOT EXISTS chunk_embedding USING vec0(
                    chunk_id INTEGER PRIMARY KEY,
                    embedding float[768]
                );

                -- Metadata for tracking computed chunk embeddings
                CREATE TABLE IF NOT EXISTS chunk_embedding_metadata (
                    chunk_id INTEGER PRIMARY KEY REFERENCES article_chunk(id) ON DELETE CASCADE,
                    computed_at REAL NOT NULL DEFAULT (unixepoch()),
                    model_name TEXT,
                    embedding_version INTEGER DEFAULT 1
                );

                -- Query history for persisting user questions and answers
                CREATE TABLE IF NOT EXISTS query_history (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    query TEXT NOT NULL,
                    answer TEXT NOT NULL,
                    related_nodes_json TEXT,
                    graph_paths_json TEXT,
                    source_articles_json TEXT,
                    created_at REAL NOT NULL DEFAULT (unixepoch())
                );
                CREATE INDEX IF NOT EXISTS idx_query_history_created ON query_history(created_at DESC);
            """)

            // Add source_chunk_id column to hypergraph_edge if it doesn't exist
            // SQLite doesn't support IF NOT EXISTS for columns, so we check first
            do {
                let columnExists = try db.columns(in: "hypergraph_edge").contains { $0.name == "source_chunk_id" }
                if !columnExists {
                    try db.execute(sql: """
                        ALTER TABLE hypergraph_edge ADD COLUMN source_chunk_id INTEGER REFERENCES article_chunk(id);
                    """)
                    try db.execute(sql: """
                        CREATE INDEX IF NOT EXISTS idx_hypergraph_edge_chunk ON hypergraph_edge(source_chunk_id);
                    """)
                }
            } catch {
                // Column might already exist, ignore error
            }

            // Add graph_paths_json column to query_history if it doesn't exist
            do {
                let columnExists = try db.columns(in: "query_history").contains { $0.name == "graph_paths_json" }
                if !columnExists {
                    try db.execute(sql: """
                        ALTER TABLE query_history ADD COLUMN graph_paths_json TEXT;
                    """)
                }
            } catch {
                // Column might already exist, ignore error
            }

            // Add reasoning_paths_json column to query_history if it doesn't exist
            do {
                let columnExists = try db.columns(in: "query_history").contains { $0.name == "reasoning_paths_json" }
                if !columnExists {
                    try db.execute(sql: """
                        ALTER TABLE query_history ADD COLUMN reasoning_paths_json TEXT;
                    """)
                }
            } catch {
                // Column might already exist, ignore error
            }

            // Add deep_analysis_json column to query_history for "Dive Deeper" feature (legacy)
            do {
                let columnExists = try db.columns(in: "query_history").contains { $0.name == "deep_analysis_json" }
                if !columnExists {
                    try db.execute(sql: """
                        ALTER TABLE query_history ADD COLUMN deep_analysis_json TEXT;
                    """)
                }
            } catch {
                // Column might already exist, ignore error
            }

            // Add separate columns for synthesized analysis and hypotheses
            do {
                let synthesizedExists = try db.columns(in: "query_history").contains { $0.name == "synthesized_analysis" }
                if !synthesizedExists {
                    try db.execute(sql: """
                        ALTER TABLE query_history ADD COLUMN synthesized_analysis TEXT;
                    """)
                }
            } catch {
                // Column might already exist, ignore error
            }

            do {
                let hypothesesExists = try db.columns(in: "query_history").contains { $0.name == "hypotheses" }
                if !hypothesesExists {
                    try db.execute(sql: """
                        ALTER TABLE query_history ADD COLUMN hypotheses TEXT;
                    """)
                }
            } catch {
                // Column might already exist, ignore error
            }

            do {
                let analyzedAtExists = try db.columns(in: "query_history").contains { $0.name == "analyzed_at" }
                if !analyzedAtExists {
                    try db.execute(sql: """
                        ALTER TABLE query_history ADD COLUMN analyzed_at REAL;
                    """)
                }
            } catch {
                // Column might already exist, ignore error
            }

            // Seed default analysis LLM settings if not present
            // Empty string means "Same as Chat LLM"
            try db.execute(sql: """
                INSERT OR IGNORE INTO app_settings (key, value) VALUES ('\(AppSettings.analysisLLMProvider)', '');
                INSERT OR IGNORE INTO app_settings (key, value) VALUES ('\(AppSettings.analysisOllamaEndpoint)', 'http://localhost:11434');
                INSERT OR IGNORE INTO app_settings (key, value) VALUES ('\(AppSettings.analysisOllamaModel)', 'llama3.2:3b');
                INSERT OR IGNORE INTO app_settings (key, value) VALUES ('\(AppSettings.analysisOpenRouterModel)', 'meta-llama/llama-4-maverick');
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
