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
                    label TEXT NOT NULL,
                    created_at REAL NOT NULL DEFAULT (unixepoch()),
                    metadata_json TEXT
                );
                CREATE INDEX IF NOT EXISTS idx_hypergraph_edge_id ON hypergraph_edge(edge_id);

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

                -- User roles for persona-based prompts
                CREATE TABLE IF NOT EXISTS user_role (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    name TEXT NOT NULL UNIQUE,
                    prompt TEXT NOT NULL,
                    is_active INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL DEFAULT (unixepoch()),
                    updated_at REAL NOT NULL DEFAULT (unixepoch())
                );
                CREATE UNIQUE INDEX IF NOT EXISTS idx_user_role_active ON user_role(is_active) WHERE is_active = 1;
            """)

            // Rename hypergraph_edge.relation → label and clean existing values.
            // The label index is created here (not in the schema block) because
            // CREATE TABLE IF NOT EXISTS is a no-op on existing databases, so the
            // column may still be called "relation" when the schema block runs.
            do {
                let hasRelationColumn = try db.columns(in: "hypergraph_edge").contains { $0.name == "relation" }
                if hasRelationColumn {
                    try db.execute(sql: "ALTER TABLE hypergraph_edge RENAME COLUMN relation TO label")
                    // Clean existing label values: extract prefix before "_chunk" from edge_id
                    try db.execute(sql: """
                        UPDATE hypergraph_edge
                        SET label = REPLACE(
                            SUBSTR(edge_id, 1, INSTR(edge_id, '_chunk') - 1),
                            '_', ' '
                        )
                        WHERE edge_id LIKE '%_chunk%' AND INSTR(edge_id, '_chunk') > 1
                    """)
                    // Drop old index and create new one
                    try db.execute(sql: "DROP INDEX IF EXISTS idx_hypergraph_edge_relation")
                }
                // Ensure label index exists (fresh installs already have `label`, upgrades just renamed it)
                try db.execute(sql: "CREATE INDEX IF NOT EXISTS idx_hypergraph_edge_label ON hypergraph_edge(label)")
            } catch {
                // Column may already have been renamed, ignore error
            }

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

            // FTS5 full-text search indexes (external content — no data duplication)
            try db.execute(sql: """
                CREATE VIRTUAL TABLE IF NOT EXISTS fts_node USING fts5(
                    label,
                    content='hypergraph_node',
                    content_rowid='id',
                    tokenize='porter unicode61'
                );

                CREATE VIRTUAL TABLE IF NOT EXISTS fts_chunk USING fts5(
                    content,
                    content='article_chunk',
                    content_rowid='id',
                    tokenize='porter unicode61'
                );
            """)

            // Sync triggers for FTS node index
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS fts_node_ai AFTER INSERT ON hypergraph_node BEGIN
                    INSERT INTO fts_node(rowid, label) VALUES (new.id, new.label);
                END;
                CREATE TRIGGER IF NOT EXISTS fts_node_ad AFTER DELETE ON hypergraph_node BEGIN
                    INSERT INTO fts_node(fts_node, rowid, label) VALUES('delete', old.id, old.label);
                END;
                CREATE TRIGGER IF NOT EXISTS fts_node_au AFTER UPDATE ON hypergraph_node BEGIN
                    INSERT INTO fts_node(fts_node, rowid, label) VALUES('delete', old.id, old.label);
                    INSERT INTO fts_node(rowid, label) VALUES (new.id, new.label);
                END;
            """)

            // Sync triggers for FTS chunk index
            try db.execute(sql: """
                CREATE TRIGGER IF NOT EXISTS fts_chunk_ai AFTER INSERT ON article_chunk BEGIN
                    INSERT INTO fts_chunk(rowid, content) VALUES (new.id, new.content);
                END;
                CREATE TRIGGER IF NOT EXISTS fts_chunk_ad AFTER DELETE ON article_chunk BEGIN
                    INSERT INTO fts_chunk(fts_chunk, rowid, content) VALUES('delete', old.id, old.content);
                END;
                CREATE TRIGGER IF NOT EXISTS fts_chunk_au AFTER UPDATE ON article_chunk BEGIN
                    INSERT INTO fts_chunk(fts_chunk, rowid, content) VALUES('delete', old.id, old.content);
                    INSERT INTO fts_chunk(rowid, content) VALUES (new.id, new.content);
                END;
            """)

            // Rebuild FTS indexes from existing data (safe to re-run)
            try db.execute(sql: "INSERT INTO fts_node(fts_node) VALUES('rebuild')")
            try db.execute(sql: "INSERT INTO fts_chunk(fts_chunk) VALUES('rebuild')")

            // Seed default settings if they don't exist
            try seedDefaultSettings(db)

            // Seed default RSS sources if none exist
            try seedDefaultRSSSources(db)
        }
    }

    /// Seeds default application settings into the database.
    /// Uses INSERT OR IGNORE to avoid overwriting existing user settings.
    private func seedDefaultSettings(_ db: GRDB.Database) throws {
        let defaultSettings: [(key: String, value: String)] = [
            // LLM Configuration
            (AppSettings.llmProvider, AppSettings.defaultLLMProvider),
            (AppSettings.ollamaEndpoint, AppSettings.defaultOllamaEndpoint),
            (AppSettings.ollamaModel, AppSettings.defaultOllamaModel),
            (AppSettings.openRouterModel, AppSettings.defaultOpenRouterModel),

            // Embedding Configuration
            (AppSettings.embeddingProvider, AppSettings.defaultEmbeddingProvider),
            (AppSettings.embeddingOllamaEndpoint, AppSettings.defaultEmbeddingOllamaEndpoint),
            (AppSettings.embeddingOllamaModel, AppSettings.defaultEmbeddingOllamaModel),
            (AppSettings.embeddingOpenRouterModel, AppSettings.defaultEmbeddingOpenRouterModel),

            // Feed Configuration
            (AppSettings.articleAgeLimitDays, String(AppSettings.defaultArticleAgeLimitDays)),

            // Algorithm Parameters
            (AppSettings.chunkSize, String(AppSettings.defaultChunkSize)),
            (AppSettings.similarityThreshold, String(AppSettings.defaultSimilarityThreshold)),
            (AppSettings.extractionTemperature, String(AppSettings.defaultExtractionTemperature)),
            (AppSettings.analysisTemperature, String(AppSettings.defaultAnalysisTemperature)),
            (AppSettings.llmMaxTokens, String(AppSettings.defaultLLMMaxTokens)),
            (AppSettings.ragMaxNodes, String(AppSettings.defaultRAGMaxNodes)),
            (AppSettings.ragMaxChunks, String(AppSettings.defaultRAGMaxChunks)),
            (AppSettings.maxPathDepth, String(AppSettings.defaultMaxPathDepth)),
            (AppSettings.maxConcurrentProcessing, String(AppSettings.defaultMaxConcurrentProcessing)),

            // Prompts
            (AppSettings.extractionSystemPrompt, AppSettings.defaultExtractionPrompt),
            (AppSettings.distillationSystemPrompt, AppSettings.defaultDistillationPrompt),
            (AppSettings.engineerAgentPrompt, AppSettings.defaultEngineerAgentPrompt),
            (AppSettings.hypothesizerAgentPrompt, AppSettings.defaultHypothesizerAgentPrompt),

            // Analysis LLM Configuration
            (AppSettings.analysisLLMProvider, AppSettings.defaultAnalysisLLMProvider),
            (AppSettings.analysisOllamaEndpoint, AppSettings.defaultAnalysisOllamaEndpoint),
            (AppSettings.analysisOllamaModel, AppSettings.defaultAnalysisOllamaModel),
            (AppSettings.analysisOpenRouterModel, AppSettings.defaultAnalysisOpenRouterModel),
        ]

        for setting in defaultSettings {
            try db.execute(
                sql: "INSERT OR IGNORE INTO app_settings (key, value) VALUES (?, ?)",
                arguments: [setting.key, setting.value]
            )
        }

        // Remove legacy single-temperature key if present
        try db.execute(
            sql: "DELETE FROM app_settings WHERE key = 'llm_temperature'"
        )

        Self.logger.info("Default settings seeded successfully")
    }

    /// Seeds default RSS sources into the database.
    /// Only seeds if no sources exist yet (first app launch).
    private func seedDefaultRSSSources(_ db: GRDB.Database) throws {
        // Check if any sources already exist
        let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source") ?? 0
        guard sourceCount == 0 else {
            Self.logger.info("RSS sources already exist, skipping seed")
            return
        }

        // Default curated feed sources
        let defaultSources: [(url: String, title: String)] = [
            // Cloud Providers
            ("https://aws.amazon.com/blogs/aws/feed", "AWS Blog"),
            ("https://aws.amazon.com/about-aws/whats-new/recent/feed", "AWS What's New"),
            ("https://azure.microsoft.com/en-us/blog/feed", "Azure Blog"),
            ("https://cloudblog.withgoogle.com/rss", "Google Cloud Blog"),
            ("https://www.digitalocean.com/blog/rss", "DigitalOcean Blog"),
            ("https://lambdalabs.com/blog/rss.xml", "Lambda Labs Blog"),

            // AI & ML
            ("https://openai.com/news/rss.xml", "OpenAI News"),
            ("https://nvidianews.nvidia.com/releases.xml", "NVIDIA News"),
            ("https://feeds.feedburner.com/nvidiablog", "NVIDIA Blog"),
            ("https://developer.nvidia.com/blog/feed", "NVIDIA Developer Blog"),

            // Tech News & Analysis
            ("https://www.semianalysis.com/feed", "SemiAnalysis"),
            ("https://www.theregister.com/headlines.atom", "The Register"),
            ("https://venturebeat.com/category/ai/feed", "VentureBeat AI"),
            ("https://news.ycombinator.com/rss", "Hacker News"),

            // GitHub Trending
            ("https://mshibanami.github.io/GitHubTrendingRSS/weekly/all.xml", "GitHub Trending"),
        ]

        for source in defaultSources {
            try db.execute(
                sql: "INSERT OR IGNORE INTO rss_source (url, title) VALUES (?, ?)",
                arguments: [source.url, source.title]
            )
        }

        Self.logger.info("Default RSS sources seeded: \(defaultSources.count) sources")
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
}
