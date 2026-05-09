import XCTest
import GRDB
@testable import NewsCombApp

/// Unit tests for `FileImportService`. Uses an in-memory `DatabaseQueue` and
/// a temp-directory fixture per test, so no live workspace is touched. We
/// inject an `ArticleIngestionService` bound to the in-memory queue, exactly
/// the way `ArticleIngestionServiceTests` does for the underlying service.
final class FileImportServiceTests: XCTestCase {

    private var dbQueue: DatabaseQueue!
    private var tempRoot: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()

        var config = Configuration()
        config.foreignKeysEnabled = true
        dbQueue = try DatabaseQueue(configuration: config)
        try dbQueue.write { db in
            try Self.createSchema(db)
        }

        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileImportServiceTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
        dbQueue = nil
        try super.tearDownWithError()
    }

    // MARK: - Happy paths

    func testImportsPlainTextAndCodeFiles() async throws {
        try writeFile("README.md", text: longBody("This is the readme. "))
        try writeFile("src/Main.swift", text: longBody("import Foundation\nfunc main() {}\n"))
        try writeFile("scripts/build.py", text: longBody("print('hello world')\n"))
        try writeFile("notes.txt", text: longBody("plain text content. "))

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "My Project", progress: nil)

        XCTAssertEqual(outcome.ingested, 4)
        XCTAssertEqual(outcome.skippedTooShort, 0)
        XCTAssertEqual(outcome.skippedUnreadable, 0)
        XCTAssertEqual(outcome.skippedTooLarge, 0)
        XCTAssertEqual(outcome.totalCandidates, 4)

        try await dbQueue.read { db in
            let sourceCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM rss_source")!
            XCTAssertEqual(sourceCount, 1, "Folder import must create exactly one manual feed")

            let sourceURL = try String.fetchOne(db, sql: "SELECT url FROM rss_source")!
            XCTAssertTrue(sourceURL.hasPrefix("manual:feed:"), "Source URL must use the manual scheme, got '\(sourceURL)'")

            let itemCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item WHERE source_id = ?", arguments: [outcome.sourceId])!
            XCTAssertEqual(itemCount, 4)

            // Titles are relative paths, so subfolder content should be distinguishable.
            let titles = try String.fetchAll(db, sql: "SELECT title FROM feed_item ORDER BY title")
            XCTAssertTrue(titles.contains("README.md"))
            XCTAssertTrue(titles.contains("notes.txt"))
            XCTAssertTrue(titles.contains("scripts/build.py"))
            XCTAssertTrue(titles.contains("src/Main.swift"))
        }
    }

    func testRecursesIntoSubfolders() async throws {
        try writeFile("a/b/c/deep.swift", text: longBody("nested file body. "))
        try writeFile("a/shallow.md", text: longBody("shallow file body. "))

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "Nested", progress: nil)

        XCTAssertEqual(outcome.ingested, 2)
        try await dbQueue.read { db in
            let titles = try String.fetchAll(db, sql: "SELECT title FROM feed_item ORDER BY title")
            XCTAssertEqual(titles, ["a/b/c/deep.swift", "a/shallow.md"])
        }
    }

    // MARK: - Skip cases

    func testSkipsFilesShorterThanMinimum() async throws {
        try writeFile("tiny.md", text: "short")  // < 100 chars
        try writeFile("ok.md", text: longBody("enough content. "))

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "F", progress: nil)

        XCTAssertEqual(outcome.ingested, 1)
        XCTAssertEqual(outcome.skippedTooShort, 1)

        try await dbQueue.read { db in
            let titles = try String.fetchAll(db, sql: "SELECT title FROM feed_item")
            XCTAssertEqual(titles, ["ok.md"])
        }
    }

    func testSkipsUnsupportedExtensions() async throws {
        try writeFile("image.png", text: "not really a png")
        try writeFile("binary.exe", text: "not really exe")
        // Log files are intentionally excluded — too noisy for the knowledge
        // graph. Pinned here so re-adding "log" to plainTextExtensions
        // produces a test failure instead of silent regression.
        try writeFile("server.log", text: longBody("2026-05-09 ERROR something happened. "))
        try writeFile("ok.swift", text: longBody("supported file. "))

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "F", progress: nil)

        XCTAssertEqual(outcome.ingested, 1)
        XCTAssertEqual(outcome.totalCandidates, 1, "Only supported extensions should be candidates; .log must not be listed")

        try await dbQueue.read { db in
            let titles = try String.fetchAll(db, sql: "SELECT title FROM feed_item")
            XCTAssertEqual(titles, ["ok.swift"], "Log file must not be ingested")
        }
    }

    func testSkipsBinaryFileWithTextExtension() async throws {
        // Write non-UTF-8 bytes to a .swift file. UTF-8 decoding must fail and
        // the file must be reported as unreadable rather than crashing.
        let badData = Data([0xFF, 0xFE, 0x00, 0x80, 0xC0, 0xC1] + Array(repeating: UInt8(0xFE), count: 200))
        let url = tempRoot.appendingPathComponent("bad.swift")
        try badData.write(to: url)

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "F", progress: nil)

        XCTAssertEqual(outcome.ingested, 0)
        XCTAssertEqual(outcome.skippedUnreadable, 1)

        try await dbQueue.read { db in
            let count = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item")!
            XCTAssertEqual(count, 0)
        }
    }

    func testStripsHTMLContent() async throws {
        let html = "<html><body><h1>Title</h1><p>" + String(repeating: "Hello world. ", count: 20) + "</p></body></html>"
        try writeFile("page.html", text: html)

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "HTML", progress: nil)

        XCTAssertEqual(outcome.ingested, 1)
        try await dbQueue.read { db in
            let body = try String.fetchOne(db, sql: "SELECT full_content FROM feed_item")!
            XCTAssertFalse(body.contains("<p>"), "HTML tags must be stripped, got: \(body.prefix(120))")
            XCTAssertFalse(body.contains("</body>"), "Closing tags must be stripped")
            XCTAssertTrue(body.contains("Hello world"))
        }
    }

    func testSkipsBuildDirectory() async throws {
        // Codebases routinely have `build/` (Xcode CLI output, Gradle, CMake)
        // and `.build/` (SwiftPM, Cargo) directories full of generated files.
        // Importing them is noise — they must be pruned even if they contain
        // files with supported extensions.
        try writeFile("build/Generated.swift", text: longBody("auto-generated. "))
        try writeFile("build/sub/dir/Other.swift", text: longBody("more auto-generated. "))
        try writeFile(".build/checkouts/Lib/Lib.swift", text: longBody("vendored dep. "))
        try writeFile("Sources/Real.swift", text: longBody("real source code. "))

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "F", progress: nil)

        XCTAssertEqual(outcome.ingested, 1)
        try await dbQueue.read { db in
            let titles = try String.fetchAll(db, sql: "SELECT title FROM feed_item ORDER BY title")
            XCTAssertEqual(titles, ["Sources/Real.swift"],
                           "build/ and .build/ subtrees must be pruned even when they hold .swift files")
        }
    }

    func testSkipsLanguageSpecificDependencyAndOutputDirectories() async throws {
        // Each excluded directory below holds a file with a supported
        // extension. Only the sibling at the project root must survive.
        // If someone removes an entry from `excludedDirectoryNames`, the
        // corresponding line here will fail loudly.

        // Generic build output
        try writeFile("dist/bundle.js", text: longBody("compiled bundle. "))
        try writeFile("out/output.swift", text: longBody("intellij output. "))
        try writeFile("coverage/lcov.json", text: longBody("coverage report. "))

        // Java / JVM
        try writeFile("target/classes/App.java", text: longBody("maven output. "))
        try writeFile("bin/Compiled.java", text: longBody("eclipse output. "))

        // JS / TS
        try writeFile("node_modules/lodash/index.js", text: longBody("dep tree. "))
        try writeFile("node_modules/.bin/eslint.js", text: longBody("dep bin. "))

        // Python
        try writeFile("__pycache__/module.cpython-311.py", text: longBody("bytecode-adjacent. "))
        try writeFile("venv/lib/python3.11/site-packages/pkg.py", text: longBody("venv dep. "))

        // Go / PHP / Ruby
        try writeFile("vendor/github.com/foo/bar/lib.go", text: longBody("vendored dep. "))

        // The one file that should win.
        try writeFile("src/Real.swift", text: longBody("actual source. "))

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "F", progress: nil)

        XCTAssertEqual(outcome.ingested, 1, "Only files outside excluded directories should be ingested")
        try await dbQueue.read { db in
            let titles = try String.fetchAll(db, sql: "SELECT title FROM feed_item")
            XCTAssertEqual(titles, ["src/Real.swift"])
        }
    }

    func testSkipsHiddenAndPackageDescendants() async throws {
        try writeFile(".git/HEAD", text: longBody("git ref content. "))
        try writeFile(".hidden.md", text: longBody("hidden markdown. "))
        try writeFile("Example.xcodeproj/project.pbxproj", text: longBody("pbxproj body. "))
        try writeFile("public.swift", text: longBody("visible swift file. "))

        let service = makeService()
        let outcome = try await service.importFolder(rootURL: tempRoot, feedTitle: "F", progress: nil)

        // Only public.swift should be ingested; .git, .hidden.md, and the
        // .xcodeproj package descendant are filtered out by the enumerator
        // options (.skipsHiddenFiles + .skipsPackageDescendants).
        XCTAssertEqual(outcome.ingested, 1)
        try await dbQueue.read { db in
            let titles = try String.fetchAll(db, sql: "SELECT title FROM feed_item")
            XCTAssertEqual(titles, ["public.swift"])
        }
    }

    // MARK: - Idempotency

    func testReimportingSameFolderUpdatesContentInPlace() async throws {
        // First pass establishes the manual feed and its articles.
        try writeFile("doc.md", text: longBody("first revision. "))
        let service = makeService()
        let first = try await service.importFolder(rootURL: tempRoot, feedTitle: "Pass1", progress: nil)

        // Re-import into the *same* feed by reusing the source id directly via
        // the underlying ArticleIngestionService. (The UI always creates a
        // fresh feed; this test exercises the upsert path that is reachable
        // via MCP today and via a future "re-import into existing feed" UI.)
        try writeFile("doc.md", text: longBody("second revision content. "))
        let ingestion = makeIngestionService()
        let body = try String(contentsOf: tempRoot.appendingPathComponent("doc.md"), encoding: .utf8)
        _ = try ingestion.ingestArticle(
            sourceId: first.sourceId,
            title: "doc.md",
            body: body,
            link: tempRoot.appendingPathComponent("doc.md").absoluteString,
            author: nil,
            pubDate: nil,
            guid: "doc.md"
        )

        try await dbQueue.read { db in
            let rowCount = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM feed_item WHERE source_id = ?", arguments: [first.sourceId])!
            XCTAssertEqual(rowCount, 1, "Same (source_id, guid) must upsert in place")
            let storedBody = try String.fetchOne(db, sql: "SELECT full_content FROM feed_item WHERE source_id = ?", arguments: [first.sourceId])!
            XCTAssertTrue(storedBody.contains("second revision"), "Body must reflect the second revision after upsert")
        }
    }

    // MARK: - Progress callback

    func testProgressCallbackFiresPerFile() async throws {
        try writeFile("a.md", text: longBody("a body. "))
        try writeFile("b.md", text: longBody("b body. "))
        try writeFile("c.md", text: longBody("c body. "))

        let service = makeService()
        let collector = ProgressCollector()
        // The callback signature is `@MainActor (...) -> Void` — sync. Both
        // the closure and `collector.append` are MainActor-isolated, so the
        // call doesn't need `await`; adding one would force the closure to
        // become async and mismatch the typealias.
        _ = try await service.importFolder(rootURL: tempRoot, feedTitle: "F") { processed, total, _ in
            collector.append(processed: processed, total: total)
        }

        let snapshots = await collector.snapshots
        XCTAssertEqual(snapshots.count, 3, "Callback must fire once per candidate")
        XCTAssertEqual(snapshots.map(\.processed), [1, 2, 3])
        XCTAssertEqual(Set(snapshots.map(\.total)), [3])
    }

    // MARK: - Helpers

    /// Pads a seed string until it comfortably exceeds
    /// `ArticleIngestionService.minimumBodyLength` (100 chars).
    private func longBody(_ seed: String) -> String {
        var s = seed
        while s.count < 150 { s += seed }
        return s
    }

    private func writeFile(_ relativePath: String, text: String) throws {
        let url = tempRoot.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try text.write(to: url, atomically: true, encoding: .utf8)
    }

    private func makeIngestionService() -> ArticleIngestionService {
        ArticleIngestionService(
            dbQueue: dbQueue,
            extract: { _ in ExtractionResult(content: nil, finalURL: nil) }
        )
    }

    private func makeService() -> FileImportService {
        FileImportService(ingestionService: makeIngestionService())
    }

    /// Schema mirrors what `ArticleIngestionServiceTests` builds — only the
    /// three tables `ArticleIngestionService` writes to. Keep these two
    /// schema definitions in sync if the production schema evolves.
    private static func createSchema(_ db: GRDB.Database) throws {
        try db.execute(sql: """
            CREATE TABLE rss_source (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                url TEXT NOT NULL UNIQUE,
                title TEXT,
                created_at REAL NOT NULL DEFAULT (unixepoch())
            );
            CREATE TABLE feed_item (
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
            CREATE TABLE article_hypergraph (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                feed_item_id INTEGER NOT NULL REFERENCES feed_item(id) ON DELETE CASCADE,
                processed_at REAL NOT NULL DEFAULT (unixepoch()),
                processing_status TEXT NOT NULL DEFAULT 'pending',
                error_message TEXT,
                chunk_count INTEGER DEFAULT 0,
                UNIQUE(feed_item_id)
            );
        """)
    }
}

/// Small actor used to collect progress callback invocations from the test.
/// The callback is `@MainActor`, so the actor's `append` must hop to the
/// main actor too — easiest to make the whole collector main-actor-isolated.
@MainActor
private final class ProgressCollector {
    struct Snapshot { let processed: Int; let total: Int }
    var snapshots: [Snapshot] = []
    func append(processed: Int, total: Int) {
        snapshots.append(Snapshot(processed: processed, total: total))
    }
}
