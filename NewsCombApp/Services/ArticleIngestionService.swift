import Foundation
import GRDB
import OSLog

private let logger = Logger(subsystem: "com.newscomb", category: "ArticleIngestionService")

/// Service for MCP-driven article ingestion: creating "manual" feed containers
/// (no real RSS URL), inserting article content sourced from an MCP client, and
/// re-fetching individual articles independently of the parent feed.
struct ArticleIngestionService: Sendable {

    /// URL scheme used for synthetic "manual" feed and article identifiers.
    /// `RSSService.fetchFeed` short-circuits on sources whose `url` starts with
    /// this scheme so the RSS parser never tries to network-fetch them.
    static let manualURLScheme = "manual"

    /// Minimum length the effective body must reach to be persisted. Mirrors
    /// the threshold `RSSService.upsertFeedItem` enforces for RSS-sourced items.
    static let minimumBodyLength = 100

    /// Outcome of a per-article refresh, returned to the MCP client so it can
    /// describe what changed without the caller having to re-query the row.
    struct RefreshOutcome: Sendable {
        let feedItemId: Int64
        let previousLink: String
        let newLink: String
        let previousContentLength: Int
        let newContentLength: Int

        var linkChanged: Bool { previousLink != newLink }
        var contentLengthDelta: Int { newContentLength - previousContentLength }
    }

    enum IngestionError: Error, LocalizedError, Sendable {
        case sourceNotFound(Int64)
        case sourceIsNotManual(Int64)
        case emptyTitle
        case bodyTooShort(actual: Int, minimum: Int)
        case feedItemNotFound(Int64)
        case missingLink(feedItemId: Int64)
        case nonHTTPLink(scheme: String)
        case extractionFailed

        var errorDescription: String? {
            switch self {
            case .sourceNotFound(let id):
                return "Source #\(id) does not exist."
            case .sourceIsNotManual(let id):
                return "Source #\(id) is a real RSS feed; ingest_article only accepts manual feeds created via create_manual_feed."
            case .emptyTitle:
                return "Title must not be empty."
            case .bodyTooShort(let actual, let minimum):
                return "Body is \(actual) chars; minimum is \(minimum)."
            case .feedItemNotFound(let id):
                return "Feed item #\(id) does not exist."
            case .missingLink(let id):
                return "Feed item #\(id) has no link to refresh from."
            case .nonHTTPLink(let scheme):
                return "Cannot refresh: link scheme '\(scheme)' is not http(s)."
            case .extractionFailed:
                return "Content extraction returned no usable content."
            }
        }
    }

    /// Closure form of `ContentExtractService.extractContentWithFinalURL` so
    /// tests can inject deterministic content without standing up a real HTTP server.
    typealias Extractor = @Sendable (String) async -> ExtractionResult

    private let dbQueue: DatabaseQueue
    private let extract: Extractor

    init(dbQueue: DatabaseQueue, extract: @escaping Extractor) {
        self.dbQueue = dbQueue
        self.extract = extract
    }

    /// Production initializer — binds to the active workspace's database and
    /// the live Postlight-backed extractor.
    init() {
        let service = ContentExtractService()
        self.init(
            dbQueue: Database.current.dbQueue,
            extract: { url in await service.extractContentWithFinalURL(from: url) }
        )
    }

    /// Returns true when `url` identifies a manual feed (or manual article
    /// placeholder) created by this service rather than a real RSS source.
    static func isManualSourceURL(_ url: String) -> Bool {
        url.hasPrefix("\(manualURLScheme):")
    }

    // MARK: - Manual feed creation

    /// Inserts a new `rss_source` row whose URL is a synthetic `manual:<uuid>`,
    /// so the standard RSS refresh path skips it but the UI continues to render it.
    @discardableResult
    func createManualFeed(title: String) throws -> RSSSource {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw IngestionError.emptyTitle
        }

        let syntheticURL = "\(Self.manualURLScheme):feed:\(UUID().uuidString)"
        let now = Date()

        let inserted = try dbQueue.write { db -> RSSSource in
            let source = RSSSource(url: syntheticURL, title: trimmed, createdAt: now)
            return try source.insertAndFetch(db)
        }

        logger.info("Created manual feed #\(inserted.id ?? -1, privacy: .public): \(trimmed, privacy: .public)")
        return inserted
    }

    // MARK: - Article ingestion

    /// Inserts (or upserts on `(source_id, guid)`) an article into a manual feed.
    /// `link` is optional; when absent a synthetic `manual:item:<uuid>` is stored
    /// so the `feed_item.link NOT NULL` constraint is honored.
    @discardableResult
    func ingestArticle(
        sourceId: Int64,
        title: String,
        body: String,
        link: String? = nil,
        author: String? = nil,
        pubDate: Date? = nil,
        guid: String? = nil
    ) throws -> FeedItem {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            throw IngestionError.emptyTitle
        }

        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmedBody.count >= Self.minimumBodyLength else {
            throw IngestionError.bodyTooShort(actual: trimmedBody.count, minimum: Self.minimumBodyLength)
        }

        let resolvedLink: String
        if let link, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            resolvedLink = link.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            resolvedLink = "\(Self.manualURLScheme):item:\(UUID().uuidString)"
        }
        let resolvedGuid = guid?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty ?? resolvedLink

        return try dbQueue.write { db -> FeedItem in
            // Verify the source exists and is a manual feed.
            guard let source = try RSSSource.filter(RSSSource.Columns.id == sourceId).fetchOne(db) else {
                throw IngestionError.sourceNotFound(sourceId)
            }
            guard Self.isManualSourceURL(source.url) else {
                throw IngestionError.sourceIsNotManual(sourceId)
            }

            try db.execute(
                sql: """
                    INSERT INTO feed_item (source_id, guid, title, link, pub_date, rss_description, full_content, author, fetched_at)
                    VALUES (?, ?, ?, ?, ?, NULL, ?, ?, unixepoch())
                    ON CONFLICT(source_id, guid) DO UPDATE SET
                        title = excluded.title,
                        link = excluded.link,
                        pub_date = excluded.pub_date,
                        full_content = excluded.full_content,
                        author = excluded.author,
                        fetched_at = unixepoch()
                """,
                arguments: [
                    sourceId,
                    resolvedGuid,
                    trimmedTitle,
                    resolvedLink,
                    pubDate?.timeIntervalSince1970,
                    trimmedBody,
                    author?.nonEmpty
                ]
            )

            guard let row = try FeedItem
                .filter(FeedItem.Columns.sourceId == sourceId)
                .filter(FeedItem.Columns.guid == resolvedGuid)
                .fetchOne(db)
            else {
                // Upsert produced no row — should be impossible. Treat as a logic error.
                throw IngestionError.feedItemNotFound(-1)
            }

            logger.info("Ingested article #\(row.id ?? -1, privacy: .public) into feed #\(sourceId, privacy: .public)")
            return row
        }
    }

    // MARK: - Per-article refresh

    /// Re-fetches `full_content` for a single article via the same Postlight
    /// extraction pipeline RSS uses, independently of the parent feed's refresh.
    @concurrent
    func refreshArticle(feedItemId: Int64) async throws -> RefreshOutcome {
        let item = try await dbQueue.read { db in
            try FeedItem.filter(FeedItem.Columns.id == feedItemId).fetchOne(db)
        }
        guard let item, let id = item.id else {
            throw IngestionError.feedItemNotFound(feedItemId)
        }

        let trimmedLink = item.link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedLink.isEmpty else {
            throw IngestionError.missingLink(feedItemId: feedItemId)
        }

        let scheme = URL(string: trimmedLink)?.scheme?.lowercased() ?? ""
        guard scheme == "http" || scheme == "https" else {
            throw IngestionError.nonHTTPLink(scheme: scheme.isEmpty ? "(none)" : scheme)
        }

        let result = await extract(trimmedLink)
        guard let content = result.content?.strippingHTMLTags(),
              content.trimmingCharacters(in: .whitespacesAndNewlines).count >= Self.minimumBodyLength
        else {
            throw IngestionError.extractionFailed
        }

        let newLink = result.finalURL ?? trimmedLink
        let previousLength = item.fullContent?.count ?? 0

        try await dbQueue.write { db in
            try db.execute(
                sql: """
                    UPDATE feed_item
                    SET full_content = ?, link = ?, fetched_at = unixepoch()
                    WHERE id = ?
                """,
                arguments: [content, newLink, id]
            )
        }

        logger.info("Refreshed article #\(id, privacy: .public) (\(previousLength, privacy: .public) → \(content.count, privacy: .public) chars)")
        return RefreshOutcome(
            feedItemId: id,
            previousLink: trimmedLink,
            newLink: newLink,
            previousContentLength: previousLength,
            newContentLength: content.count
        )
    }
}

private extension String {
    /// Returns nil when the string is empty after trimming, otherwise the trimmed string.
    /// Used to coerce empty MCP-tool inputs to SQL NULL.
    var nonEmpty: String? {
        let trimmed = self.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
