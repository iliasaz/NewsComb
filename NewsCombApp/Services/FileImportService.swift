import Foundation
import OSLog
#if canImport(PDFKit)
import PDFKit
#endif

private let logger = Logger(subsystem: "com.newscomb", category: "FileImportService")

/// Service that walks a folder, extracts text from each supported file, and
/// hands the results to `ArticleIngestionService` to insert into a freshly
/// created manual feed. Mirrors the MCP `create_manual_feed` + `ingest_article`
/// flow so UI imports are byte-for-byte indistinguishable from MCP imports.
///
/// The folder import primarily targets *codebase* ingestion (the user wants to
/// load a project into NewsComb so the knowledge-graph extractor can mine
/// cross-file relationships) but transparently handles plain text, Markdown,
/// HTML, and PDF as well.
struct FileImportService: Sendable {

    /// Aggregated outcome reported back to the UI after a folder import.
    struct Outcome: Sendable {
        var sourceId: Int64
        var sourceTitle: String
        var ingested: Int = 0
        var skippedTooShort: Int = 0
        var skippedUnreadable: Int = 0
        var skippedUnsupported: Int = 0
        var skippedTooLarge: Int = 0
        var totalCandidates: Int = 0
    }

    /// Per-file progress callback invoked on the main actor so the view model
    /// can update observable state without crossing isolation boundaries.
    typealias Progress = @MainActor @Sendable (_ processed: Int, _ total: Int, _ currentRelativePath: String) -> Void

    /// Extensions whose contents we read verbatim as UTF-8 text. Covers the
    /// common code formats the user listed (Swift, Java, Python, C/C++, TS/JS,
    /// SQL, Go, Rust) plus generic text/markdown and structured data formats.
    /// `.log` is deliberately excluded — log files are mostly machine-generated
    /// noise (timestamps, stack traces) that would pollute the knowledge graph.
    static let plainTextExtensions: Set<String> = [
        "txt", "text", "md", "markdown", "rst",
        "swift",
        "java", "kt", "kts", "scala", "groovy",
        "py", "rb", "php", "pl",
        "c", "h", "cc", "cpp", "cxx", "hpp", "hh", "m", "mm",
        "ts", "tsx", "js", "jsx", "mjs", "cjs",
        "go", "rs",
        "sql",
        "yaml", "yml", "toml", "json", "ini", "cfg", "conf", "env",
        "xml", "csv", "tsv",
        "sh", "bash", "zsh", "fish",
        "dockerfile", "makefile", "gradle"
    ]
    static let htmlExtensions: Set<String> = ["html", "htm", "xhtml"]
    static let pdfExtensions: Set<String> = ["pdf"]

    /// Directory names whose contents we never want to import — generated
    /// build output, dependency caches, and virtualenvs that would balloon
    /// the article count without adding signal. Compared lowercase against
    /// `lastPathComponent` so APFS case-insensitivity (and the rare
    /// case-sensitive volume) both work.
    ///
    /// Anything starting with `.` (e.g. `.build`, `.gradle`, `.idea`,
    /// `.next`, `.venv`, `.tox`, `.pytest_cache`, `.mypy_cache`) is already
    /// pruned by `.skipsHiddenFiles` on the enumerator, so it doesn't need
    /// to appear here.
    static let excludedDirectoryNames: Set<String> = [
        // Generic / cross-language
        "build",         // Xcode CLI, Gradle, CMake, generic
        "dist",          // distribution / build output across many ecosystems
        "out",           // IntelliJ default, Next.js
        "coverage",      // test coverage report output

        // Java / JVM
        "target",        // Maven (and Rust Cargo — same name)
        "bin",           // Eclipse-style compiled classes

        // JavaScript / TypeScript
        "node_modules",  // npm / yarn / pnpm dep tree

        // Python
        "__pycache__",   // bytecode cache
        "venv",          // virtualenv (the non-hidden variant; `.venv` is hidden)

        // Go (also PHP, Ruby)
        "vendor"
    ]

    /// Skip files larger than this. 5 MB easily fits any source-code file but
    /// drops vendored bundles or generated lockfiles dressed as `.json`.
    static let maxFileSizeBytes: Int = 5 * 1024 * 1024

    private let ingestionService: ArticleIngestionService

    /// Test-friendly initializer: callers inject an `ArticleIngestionService`
    /// bound to whatever `DatabaseQueue` they want (in-memory for unit tests).
    init(ingestionService: ArticleIngestionService) {
        self.ingestionService = ingestionService
    }

    /// Production initializer — binds to `ArticleIngestionService()` which in
    /// turn binds to the active workspace's `Database.current`.
    init() {
        self.init(ingestionService: ArticleIngestionService())
    }

    /// Walks `rootURL` recursively, ingests every supported file as an article
    /// inside a new manual feed titled `feedTitle`, and returns a summary.
    ///
    /// The whole walk runs off the main actor so a large codebase doesn't
    /// stutter the UI; only the `progress` callback hops back onto `@MainActor`.
    @concurrent
    func importFolder(
        rootURL: URL,
        feedTitle: String,
        progress: Progress? = nil
    ) async throws -> Outcome {
        let source = try ingestionService.createManualFeed(title: feedTitle)
        guard let sourceId = source.id else {
            // createManualFeed always returns a row with an id; this is
            // belt-and-suspenders for the type system.
            throw IngestionError.feedCreationReturnedNoId
        }

        var outcome = Outcome(sourceId: sourceId, sourceTitle: source.title ?? feedTitle)

        let candidates = collectCandidates(at: rootURL)
        outcome.totalCandidates = candidates.count

        var processed = 0
        for candidate in candidates {
            try Task.checkCancellation()
            processed += 1
            let relativePath = candidate.relativePath

            switch ingestSingle(candidate: candidate, sourceId: sourceId) {
            case .ingested:
                outcome.ingested += 1
            case .skippedTooShort:
                outcome.skippedTooShort += 1
            case .skippedUnreadable:
                outcome.skippedUnreadable += 1
            case .skippedTooLarge:
                outcome.skippedTooLarge += 1
            }

            if let progress {
                let snapshot = (processed, candidates.count, relativePath)
                await progress(snapshot.0, snapshot.1, snapshot.2)
            }
        }

        logger.info("""
            Folder import complete: ingested \(outcome.ingested, privacy: .public), \
            skippedTooShort \(outcome.skippedTooShort, privacy: .public), \
            skippedUnreadable \(outcome.skippedUnreadable, privacy: .public), \
            skippedTooLarge \(outcome.skippedTooLarge, privacy: .public), \
            unsupported \(outcome.skippedUnsupported, privacy: .public)
        """)

        return outcome
    }

    // MARK: - Internal helpers

    enum IngestionError: Error, LocalizedError {
        case feedCreationReturnedNoId

        var errorDescription: String? {
            switch self {
            case .feedCreationReturnedNoId:
                return "Manual feed was created but no row id was returned."
            }
        }
    }

    /// One file under the import root. We only enumerate supported extensions
    /// up-front so the per-file step never has to consult the unsupported list.
    struct Candidate {
        var url: URL
        var relativePath: String
        var extensionLower: String
        var fileSize: Int
        var modificationDate: Date?
    }

    private enum SingleResult {
        case ingested
        case skippedTooShort
        case skippedUnreadable
        case skippedTooLarge
    }

    /// Enumerates `rootURL`, returning every regular file with a supported
    /// extension. Hidden files and package descendants (`.xcodeproj`, `.app`)
    /// are skipped via enumerator options. We collect the full candidate list
    /// before ingesting so the progress callback can report a meaningful total.
    private func collectCandidates(at rootURL: URL) -> [Candidate] {
        let resourceKeys: Set<URLResourceKey> = [
            .isRegularFileKey,
            .fileSizeKey,
            .contentModificationDateKey
        ]

        guard let enumerator = FileManager.default.enumerator(
            at: rootURL,
            includingPropertiesForKeys: Array(resourceKeys),
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else {
            return []
        }

        let rootPath = rootURL.standardizedFileURL.path
        var out: [Candidate] = []

        for case let url as URL in enumerator {
            let standardized = url.standardizedFileURL

            // Prune build-output subtrees before descending. `skipDescendants`
            // is a no-op for regular files, so the unconditional check is
            // safe — and a regular file literally named `build` (no
            // extension) would also fail the supported-extension filter
            // below, so we lose nothing by short-circuiting here.
            if Self.excludedDirectoryNames.contains(standardized.lastPathComponent.lowercased()) {
                enumerator.skipDescendants()
                continue
            }

            guard let values = try? standardized.resourceValues(forKeys: resourceKeys),
                  values.isRegularFile == true
            else { continue }

            let ext = standardized.pathExtension.lowercased()
            guard isSupportedExtension(ext, filename: standardized.lastPathComponent) else { continue }

            let fileSize = values.fileSize ?? 0
            let relative = relativePath(of: standardized.path, under: rootPath)
                ?? standardized.lastPathComponent

            out.append(Candidate(
                url: standardized,
                relativePath: relative,
                extensionLower: ext,
                fileSize: fileSize,
                modificationDate: values.contentModificationDate
            ))
        }

        return out
    }

    /// Strips `rootPath` (plus its trailing slash) from `path`, or returns nil
    /// when `path` doesn't sit under `rootPath` after standardization.
    private func relativePath(of path: String, under rootPath: String) -> String? {
        let prefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard path.hasPrefix(prefix) else { return nil }
        return String(path.dropFirst(prefix.count))
    }

    /// Some extensionless files (e.g. `Dockerfile`, `Makefile`) are still
    /// readable as plain text; match them by exact filename in lowercase.
    private func isSupportedExtension(_ ext: String, filename: String) -> Bool {
        if Self.plainTextExtensions.contains(ext) { return true }
        if Self.htmlExtensions.contains(ext) { return true }
        if Self.pdfExtensions.contains(ext) { return true }
        if ext.isEmpty {
            let lowerName = filename.lowercased()
            return Self.plainTextExtensions.contains(lowerName)
        }
        return false
    }

    /// Reads, extracts, and ingests one file. Returns which bucket the file
    /// landed in so the caller can update the outcome counters.
    private func ingestSingle(candidate: Candidate, sourceId: Int64) -> SingleResult {
        if candidate.fileSize > Self.maxFileSizeBytes {
            return .skippedTooLarge
        }

        let body: String?
        if Self.plainTextExtensions.contains(candidate.extensionLower)
            || (candidate.extensionLower.isEmpty
                && Self.plainTextExtensions.contains(candidate.url.lastPathComponent.lowercased()))
        {
            body = readUTF8(candidate.url)
        } else if Self.htmlExtensions.contains(candidate.extensionLower) {
            body = readUTF8(candidate.url)?.strippingHTMLTags()
        } else if Self.pdfExtensions.contains(candidate.extensionLower) {
            body = readPDF(candidate.url)
        } else {
            // collectCandidates already filtered to supported extensions, so
            // reaching here means a logic bug rather than user input we should
            // tolerate silently — but treat as unreadable to avoid a crash.
            return .skippedUnreadable
        }

        guard let body, !body.isEmpty else {
            return .skippedUnreadable
        }

        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= ArticleIngestionService.minimumBodyLength else {
            return .skippedTooShort
        }

        do {
            _ = try ingestionService.ingestArticle(
                sourceId: sourceId,
                title: candidate.relativePath,
                body: trimmed,
                link: candidate.url.absoluteString,
                author: nil,
                pubDate: candidate.modificationDate,
                guid: candidate.relativePath
            )
            return .ingested
        } catch {
            logger.error("Failed to ingest \(candidate.relativePath, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return .skippedUnreadable
        }
    }

    private func readUTF8(_ url: URL) -> String? {
        do {
            return try String(contentsOf: url, encoding: .utf8)
        } catch {
            return nil
        }
    }

    private func readPDF(_ url: URL) -> String? {
        #if canImport(PDFKit)
        guard let document = PDFDocument(url: url) else { return nil }
        return document.string
        #else
        return nil
        #endif
    }
}
