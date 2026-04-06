import XCTest
import GRDB
import MCP
@testable import NewsCombApp

// MARK: - Test Database Helper

/// Creates an in-memory database with the schema needed by MCP tools.
private func makeTestDatabase() throws -> InMemoryDatabaseReader {
    let dbQueue = try DatabaseQueue()
    try dbQueue.write { db in
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
                link TEXT,
                pub_date REAL,
                author TEXT,
                fetched_at REAL NOT NULL DEFAULT (unixepoch()),
                UNIQUE(source_id, guid)
            );
            CREATE TABLE hypergraph_node (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                node_id TEXT NOT NULL UNIQUE,
                label TEXT NOT NULL,
                node_type TEXT,
                df INTEGER DEFAULT 0,
                idf REAL DEFAULT 0
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
            CREATE TABLE node_embedding_metadata (
                node_id INTEGER PRIMARY KEY,
                computed_at REAL NOT NULL DEFAULT (unixepoch()),
                model_name TEXT
            );
            CREATE TABLE clusters (
                cluster_id INTEGER NOT NULL,
                build_id TEXT NOT NULL,
                size INTEGER,
                label TEXT,
                summary TEXT,
                top_entities_json TEXT,
                top_rel_families_json TEXT,
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
            CREATE TABLE query_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                query TEXT NOT NULL,
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE app_settings (
                key TEXT PRIMARY KEY,
                value TEXT NOT NULL
            );

            -- FTS5 virtual tables
            CREATE VIRTUAL TABLE fts_node USING fts5(label, content=hypergraph_node, content_rowid=id);
            CREATE VIRTUAL TABLE fts_chunk USING fts5(content, content=article_chunk, content_rowid=id);
            CREATE VIRTUAL TABLE fts_cluster USING fts5(label, summary, content=clusters, content_rowid=cluster_id);
        """)
    }
    return InMemoryDatabaseReader(dbQueue: dbQueue)
}

/// Inserts a standard set of test data into the database.
private func insertTestData(_ dbQueue: DatabaseQueue) throws {
    try dbQueue.write { db in
        // Sources and articles
        try db.execute(sql: "INSERT INTO rss_source (id, url, title) VALUES (1, 'https://example.com/feed', 'Tech News')")
        try db.execute(sql: "INSERT INTO feed_item (id, source_id, guid, title, link, pub_date) VALUES (10, 1, 'g1', 'NVIDIA Launches New AI Chip', 'https://example.com/nvidia', 1712000000)")
        try db.execute(sql: "INSERT INTO feed_item (id, source_id, guid, title, link, pub_date) VALUES (11, 1, 'g2', 'AMD Partners with Microsoft', 'https://example.com/amd', 1712100000)")
        try db.execute(sql: "INSERT INTO article_hypergraph (feed_item_id, processing_status) VALUES (10, 'completed')")
        try db.execute(sql: "INSERT INTO article_hypergraph (feed_item_id, processing_status) VALUES (11, 'completed')")

        // Chunks
        try db.execute(sql: "INSERT INTO article_chunk (id, feed_item_id, chunk_index, content) VALUES (100, 10, 0, 'NVIDIA announced a groundbreaking AI chip for data centers.')")
        try db.execute(sql: "INSERT INTO article_chunk (id, feed_item_id, chunk_index, content) VALUES (101, 11, 0, 'AMD and Microsoft announced a strategic partnership for cloud AI.')")

        // FTS chunk index
        try db.execute(sql: "INSERT INTO fts_chunk(rowid, content) VALUES (100, 'NVIDIA announced a groundbreaking AI chip for data centers.')")
        try db.execute(sql: "INSERT INTO fts_chunk(rowid, content) VALUES (101, 'AMD and Microsoft announced a strategic partnership for cloud AI.')")

        // Nodes
        try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label, node_type, df) VALUES (1, 'nvidia', 'NVIDIA', 'Organization', 5)")
        try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label, node_type, df) VALUES (2, 'amd', 'AMD', 'Organization', 3)")
        try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label, node_type, df) VALUES (3, 'microsoft', 'Microsoft', 'Organization', 4)")
        try db.execute(sql: "INSERT INTO hypergraph_node (id, node_id, label, node_type, df) VALUES (4, 'ai_chip', 'AI chip', 'Technology', 2)")

        // FTS node index
        try db.execute(sql: "INSERT INTO fts_node(rowid, label) VALUES (1, 'NVIDIA')")
        try db.execute(sql: "INSERT INTO fts_node(rowid, label) VALUES (2, 'AMD')")
        try db.execute(sql: "INSERT INTO fts_node(rowid, label) VALUES (3, 'Microsoft')")
        try db.execute(sql: "INSERT INTO fts_node(rowid, label) VALUES (4, 'AI chip')")

        // Edges
        try db.execute(sql: "INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id) VALUES (1, 'launches_chunk100_0', 'launches', 100)")
        try db.execute(sql: "INSERT INTO hypergraph_edge (id, edge_id, label, source_chunk_id) VALUES (2, 'partners_with_chunk101_0', 'partners with', 101)")

        // Incidence (who participates in each edge)
        try db.execute(sql: "INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES (1, 1, 'source', 0)") // NVIDIA launches
        try db.execute(sql: "INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES (1, 4, 'target', 0)") // AI chip
        try db.execute(sql: "INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES (2, 2, 'source', 0)") // AMD partners
        try db.execute(sql: "INSERT INTO hypergraph_incidence (edge_id, node_id, role, position) VALUES (2, 3, 'target', 0)") // Microsoft

        // Provenance
        try db.execute(sql: "INSERT INTO article_edge_provenance (edge_id, feed_item_id, chunk_index, chunk_text) VALUES (1, 10, 0, 'NVIDIA announced a groundbreaking AI chip')")
        try db.execute(sql: "INSERT INTO article_edge_provenance (edge_id, feed_item_id, chunk_index, chunk_text) VALUES (2, 11, 0, 'AMD and Microsoft announced a partnership')")

        // Embedding metadata
        try db.execute(sql: "INSERT INTO node_embedding_metadata (node_id) VALUES (1)")
        try db.execute(sql: "INSERT INTO node_embedding_metadata (node_id) VALUES (2)")

        // Clusters
        try db.execute(sql: """
            INSERT INTO clusters (cluster_id, build_id, size, label, summary, top_entities_json, top_rel_families_json)
            VALUES (1, 'b1', 2, 'AI Chip Race', 'Competition in AI hardware market.',
                    '[{"label":"NVIDIA","score":0.9},{"label":"AMD","score":0.7}]',
                    '[{"family":"launches","count":1},{"family":"partners_with","count":1}]')
        """)
        try db.execute(sql: "INSERT INTO cluster_members (cluster_id, event_id, membership) VALUES (1, 1, 0.9)")
        try db.execute(sql: "INSERT INTO cluster_members (cluster_id, event_id, membership) VALUES (1, 2, 0.8)")
        try db.execute(sql: "INSERT INTO cluster_exemplars (cluster_id, event_id, rank) VALUES (1, 1, 0)")

        // FTS cluster index
        try db.execute(sql: "INSERT INTO fts_cluster(rowid, label, summary) VALUES (1, 'AI Chip Race', 'Competition in AI hardware market.')")
    }
}

// MARK: - MCPToolError Tests

final class MCPToolErrorTests: XCTestCase {

    func testMissingParameterMessage() {
        let error = MCPToolError.missingParameter("query")
        XCTAssertEqual(error.message, "Missing required parameter: query")
    }

    func testInvalidParameterMessage() {
        let error = MCPToolError.invalidParameter("limit", detail: "must be positive")
        XCTAssertEqual(error.message, "Invalid parameter 'limit': must be positive")
    }

    func testNotFoundMessage() {
        let error = MCPToolError.notFound("Node 'foo' not found")
        XCTAssertEqual(error.message, "Not found: Node 'foo' not found")
    }

    func testDatabaseErrorMessage() {
        struct TestError: Error, CustomStringConvertible {
            var description: String { "disk full" }
        }
        let error = MCPToolError.database(TestError())
        XCTAssertTrue(error.message.contains("Database error"))
    }
}

// MARK: - Keyword Extraction Tests

final class KeywordExtractionTests: XCTestCase {

    // MARK: - Fallback Extraction Tests

    func testFallbackExtractsKeywordsFromQuestion() {
        let keywords = KeywordExtractionService.extractKeywordsFallback(
            from: "What are the connections between NVIDIA and the AI chip market?"
        )
        XCTAssertTrue(keywords.contains("nvidia"))
        XCTAssertTrue(keywords.contains("chip"))
        XCTAssertTrue(keywords.contains("market"))
        // Stopwords should be filtered
        XCTAssertFalse(keywords.contains("the"))
        XCTAssertFalse(keywords.contains("and"))
        XCTAssertFalse(keywords.contains("are"))
    }

    func testFallbackMaxFiveKeywords() {
        let keywords = KeywordExtractionService.extractKeywordsFallback(
            from: "alpha bravo charlie delta echo foxtrot golf hotel india juliet"
        )
        XCTAssertLessThanOrEqual(keywords.count, 5)
    }

    func testFallbackFiltersShortWords() {
        let keywords = KeywordExtractionService.extractKeywordsFallback(from: "Is AI an OK topic?")
        // "is", "ai" (2 chars), "an", "ok" (2 chars) should all be filtered
        XCTAssertFalse(keywords.contains("is"))
        XCTAssertFalse(keywords.contains("an"))
    }

    func testFallbackEmptyQuestionReturnsEmpty() {
        let keywords = KeywordExtractionService.extractKeywordsFallback(from: "")
        XCTAssertTrue(keywords.isEmpty)
    }

    func testFallbackStopwordsOnlyReturnsEmpty() {
        let keywords = KeywordExtractionService.extractKeywordsFallback(from: "what is the how and why")
        XCTAssertTrue(keywords.isEmpty)
    }

    func testFallbackDeduplicatesKeywords() {
        let keywords = KeywordExtractionService.extractKeywordsFallback(
            from: "NVIDIA NVIDIA NVIDIA market"
        )
        let nvidiaCount = keywords.filter { $0 == "nvidia" }.count
        XCTAssertEqual(nvidiaCount, 1)
    }

    // MARK: - JSON Parsing Tests

    func testParsesValidKeywordJSON() {
        let json = """
            {"keywords": ["Google Cloud", "partners", "AI"]}
            """
        let result = KeywordExtractionService.parseKeywordsFromJSON(json)
        XCTAssertEqual(result, ["Google Cloud", "partners", "AI"])
    }

    func testParsesKeywordJSONWithCodeBlock() {
        let json = """
            ```json
            {"keywords": ["NVIDIA", "AMD"]}
            ```
            """
        let result = KeywordExtractionService.parseKeywordsFromJSON(json)
        XCTAssertEqual(result, ["NVIDIA", "AMD"])
    }

    func testReturnsNilForEmptyKeywords() {
        let json = """
            {"keywords": []}
            """
        let result = KeywordExtractionService.parseKeywordsFromJSON(json)
        XCTAssertNil(result)
    }

    func testReturnsNilForInvalidJSON() {
        let result = KeywordExtractionService.parseKeywordsFromJSON("not json at all")
        XCTAssertNil(result)
    }

    func testReturnsNilForMissingKeywordsKey() {
        let json = """
            {"entities": ["NVIDIA"]}
            """
        let result = KeywordExtractionService.parseKeywordsFromJSON(json)
        XCTAssertNil(result)
    }

    func testPreservesMultiWordKeywords() {
        let json = """
            {"keywords": ["Google Cloud", "machine learning", "New York"]}
            """
        let result = KeywordExtractionService.parseKeywordsFromJSON(json)
        XCTAssertEqual(result?.count, 3)
        XCTAssertTrue(result?.contains("Google Cloud") ?? false)
        XCTAssertTrue(result?.contains("machine learning") ?? false)
    }
}

// MARK: - SearchConceptsTool Tests

final class MCPSearchConceptsToolTests: XCTestCase {

    func testMissingQueryThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(try MCPSearchConceptsTool.run(arguments: [:], database: db)) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("query") ?? false)
        }
    }

    func testEmptyQueryThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(
            try MCPSearchConceptsTool.run(arguments: ["query": .string("")], database: db)
        )
    }

    func testFindsMatchingConcepts() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("NVIDIA")],
            database: db
        )
        XCTAssertTrue(result.contains("NVIDIA"))
        XCTAssertTrue(result.contains("Organization"))
    }

    func testNoMatchReturnsNotFoundMessage() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("nonexistent_xyz_concept")],
            database: db
        )
        XCTAssertTrue(result.contains("No concepts found"))
    }

    func testLimitParameter() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        // FTS5 prefix query: "NVI*" matches "NVIDIA", limit to 1 result
        let result = try MCPSearchConceptsTool.run(
            arguments: ["query": .string("NVI*"), "limit": .int(1)],
            database: db
        )
        // Should only have 1 result entry (one "- **" line)
        let matchCount = result.components(separatedBy: "- **").count - 1
        XCTAssertEqual(matchCount, 1)
    }
}

// MARK: - SearchChunksTool Tests

final class MCPSearchChunksToolTests: XCTestCase {

    func testMissingQueryThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(try MCPSearchChunksTool.run(arguments: [:], database: db))
    }

    func testFindsMatchingChunks() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPSearchChunksTool.run(
            arguments: ["query": .string("NVIDIA")],
            database: db
        )
        XCTAssertTrue(result.contains("NVIDIA"))
        XCTAssertTrue(result.contains("groundbreaking"))
    }

    func testNoMatchReturnsNotFoundMessage() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPSearchChunksTool.run(
            arguments: ["query": .string("zzz_nonexistent_term")],
            database: db
        )
        XCTAssertTrue(result.contains("No article content found"))
    }
}

// MARK: - GetNodeNeighborsTool Tests

final class MCPGetNodeNeighborsToolTests: XCTestCase {

    func testMissingNodeLabelThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(try MCPGetNodeNeighborsTool.run(arguments: [:], database: db))
    }

    func testNodeNotFoundThrowsError() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        XCTAssertThrowsError(
            try MCPGetNodeNeighborsTool.run(
                arguments: ["node_label": .string("Nonexistent Corp")],
                database: db
            )
        ) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("Not found") ?? false)
        }
    }

    func testFindsNeighborsForNode() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetNodeNeighborsTool.run(
            arguments: ["node_label": .string("NVIDIA")],
            database: db
        )
        XCTAssertTrue(result.contains("NVIDIA"))
        XCTAssertTrue(result.contains("Organization"))
        XCTAssertTrue(result.contains("launches"))
    }

    func testCaseInsensitiveLookup() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetNodeNeighborsTool.run(
            arguments: ["node_label": .string("nvidia")],
            database: db
        )
        XCTAssertTrue(result.contains("NVIDIA"))
    }
}

// MARK: - GetStatisticsTool Tests

final class MCPGetStatisticsToolTests: XCTestCase {

    func testReturnsStatisticsOnEmptyDatabase() throws {
        let db = try makeTestDatabase()

        let result = try MCPGetStatisticsTool.run(arguments: [:], database: db)
        XCTAssertTrue(result.contains("Knowledge Graph Statistics"))
        XCTAssertTrue(result.contains("| Graph Nodes (Entities) | 0 |"))
    }

    func testReturnsCorrectCounts() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetStatisticsTool.run(arguments: [:], database: db)
        XCTAssertTrue(result.contains("| RSS Sources | 1 |"))
        XCTAssertTrue(result.contains("| Total Articles | 2 |"))
        XCTAssertTrue(result.contains("| Processed Articles | 2 |"))
        XCTAssertTrue(result.contains("| Graph Nodes (Entities) | 4 |"))
        XCTAssertTrue(result.contains("| Graph Edges (Relationships) | 2 |"))
        XCTAssertTrue(result.contains("| Node Embeddings | 2 |"))
    }

    func testEntityTypeDistribution() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetStatisticsTool.run(arguments: [:], database: db)
        XCTAssertTrue(result.contains("Organization: 3"))
        XCTAssertTrue(result.contains("Technology: 1"))
    }
}

// MARK: - GetRecentArticlesTool Tests

final class MCPGetRecentArticlesToolTests: XCTestCase {

    func testReturnsArticles() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetRecentArticlesTool.run(arguments: [:], database: db)
        XCTAssertTrue(result.contains("NVIDIA Launches New AI Chip"))
        XCTAssertTrue(result.contains("AMD Partners with Microsoft"))
        XCTAssertTrue(result.contains("[processed]"))
    }

    func testSourceFilter() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetRecentArticlesTool.run(
            arguments: ["source": .string("Tech News")],
            database: db
        )
        XCTAssertTrue(result.contains("Tech News"))
    }

    func testNoMatchingSource() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetRecentArticlesTool.run(
            arguments: ["source": .string("Nonexistent Source")],
            database: db
        )
        XCTAssertTrue(result.contains("No articles found"))
    }

    func testLimitParameter() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetRecentArticlesTool.run(
            arguments: ["limit": .int(1)],
            database: db
        )
        // Should contain exactly one article (the most recent by pub_date)
        XCTAssertTrue(result.contains("AMD Partners with Microsoft"))
        XCTAssertFalse(result.contains("NVIDIA Launches"))
    }

    func testEmptyDatabaseReturnsMessage() throws {
        let db = try makeTestDatabase()

        let result = try MCPGetRecentArticlesTool.run(arguments: [:], database: db)
        XCTAssertTrue(result.contains("No articles found"))
    }
}

// MARK: - GetThemesTool Tests

final class MCPGetThemesToolTests: XCTestCase {

    func testListsThemes() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetThemesTool.run(arguments: [:], database: db)
        XCTAssertTrue(result.contains("AI Chip Race"))
        XCTAssertTrue(result.contains("2 events"))
        XCTAssertTrue(result.contains("NVIDIA"))
    }

    func testSearchThemes() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetThemesTool.run(
            arguments: ["query": .string("AI")],
            database: db
        )
        XCTAssertTrue(result.contains("AI Chip Race"))
    }

    func testSearchNoMatch() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetThemesTool.run(
            arguments: ["query": .string("zzz_nonexistent")],
            database: db
        )
        XCTAssertTrue(result.contains("No themes found"))
    }

    func testEmptyDatabaseReturnsMessage() throws {
        let db = try makeTestDatabase()

        let result = try MCPGetThemesTool.run(arguments: [:], database: db)
        XCTAssertTrue(result.contains("No story themes found"))
    }
}

// MARK: - GetThemeDetailsTool Tests

final class MCPGetThemeDetailsToolTests: XCTestCase {

    func testMissingClusterIdThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(try MCPGetThemeDetailsTool.run(arguments: [:], database: db))
    }

    func testNonexistentClusterThrowsError() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        XCTAssertThrowsError(
            try MCPGetThemeDetailsTool.run(arguments: ["cluster_id": .int(999)], database: db)
        ) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("Not found") ?? false)
        }
    }

    func testReturnsClusterDetails() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        let result = try MCPGetThemeDetailsTool.run(
            arguments: ["cluster_id": .int(1)],
            database: db
        )
        XCTAssertTrue(result.contains("AI Chip Race"))
        XCTAssertTrue(result.contains("2 events"))
        XCTAssertTrue(result.contains("Competition in AI hardware"))
        XCTAssertTrue(result.contains("NVIDIA"))
        XCTAssertTrue(result.contains("launches"))
    }
}

// MARK: - FindPathsTool Parameter Validation Tests

final class MCPFindPathsToolTests: XCTestCase {

    func testMissingSourceThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(
            try MCPFindPathsTool.run(arguments: ["target": .string("AMD")], database: db)
        ) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("source") ?? false)
        }
    }

    func testMissingTargetThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(
            try MCPFindPathsTool.run(arguments: ["source": .string("NVIDIA")], database: db)
        ) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("target") ?? false)
        }
    }

    func testEmptySourceThrowsError() throws {
        let db = try makeTestDatabase()
        XCTAssertThrowsError(
            try MCPFindPathsTool.run(
                arguments: ["source": .string(""), "target": .string("AMD")],
                database: db
            )
        )
    }

    func testSourceNotFoundThrowsError() throws {
        let db = try makeTestDatabase()
        try insertTestData(db.dbQueue)

        XCTAssertThrowsError(
            try MCPFindPathsTool.run(
                arguments: ["source": .string("NonexistentCorp"), "target": .string("AMD")],
                database: db
            )
        ) { error in
            XCTAssertTrue((error as? MCPToolError)?.message.contains("Not found") ?? false)
        }
    }
}

// MARK: - MCPToolDispatcher Tests

final class MCPToolDispatcherTests: XCTestCase {

    func testUnknownToolThrowsError() async throws {
        do {
            _ = try await MCPToolDispatcher.dispatch(toolName: "nonexistent_tool", arguments: [:])
            XCTFail("Should have thrown")
        } catch let error as MCPToolError {
            XCTAssertTrue(error.message.contains("Unknown tool"))
            XCTAssertTrue(error.message.contains("nonexistent_tool"))
        }
    }
}

// MARK: - MCPHelperTypes Tests

final class MCPHelperTypesTests: XCTestCase {

    func testRankedEntityDecoding() throws {
        let json = """
            [{"label":"NVIDIA","score":0.95},{"label":"AMD","score":0.72}]
        """
        let entities = try JSONDecoder().decode([MCPRankedEntity].self, from: Data(json.utf8))
        XCTAssertEqual(entities.count, 2)
        XCTAssertEqual(entities[0].label, "NVIDIA")
        XCTAssertEqual(entities[0].score, 0.95, accuracy: 0.001)
        XCTAssertEqual(entities[1].label, "AMD")
    }

    func testRankedFamilyDecoding() throws {
        let json = """
            [{"family":"launches","count":5},{"family":"partners_with","count":3}]
        """
        let families = try JSONDecoder().decode([MCPRankedFamily].self, from: Data(json.utf8))
        XCTAssertEqual(families.count, 2)
        XCTAssertEqual(families[0].family, "launches")
        XCTAssertEqual(families[0].count, 5)
    }
}

// MARK: - MCPDatabaseReader Protocol Tests

final class MCPDatabaseReaderTests: XCTestCase {

    func testInMemoryDatabaseReaderRead() throws {
        let dbQueue = try DatabaseQueue()
        try dbQueue.write { db in
            try db.execute(sql: "CREATE TABLE test (id INTEGER PRIMARY KEY, name TEXT)")
            try db.execute(sql: "INSERT INTO test (id, name) VALUES (1, 'hello')")
        }

        let reader = InMemoryDatabaseReader(dbQueue: dbQueue)
        let name = try reader.read { db in
            try String.fetchOne(db, sql: "SELECT name FROM test WHERE id = 1")
        }
        XCTAssertEqual(name, "hello")
    }
}
