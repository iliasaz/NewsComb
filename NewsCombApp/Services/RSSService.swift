import Foundation
@preconcurrency import FeedKit
import GRDB
import OSLog

private let logger = Logger(subsystem: "com.newscomb", category: "RSSService")

struct FetchResult: Sendable {
    let sourceId: Int64
    let sourceName: String
    let itemCount: Int
    let error: Error?
}

struct RSSService {
    private let database = Database.shared

    /// Returns the article age limit in days from settings, or the default value.
    private func getArticleAgeLimitDays() -> Int {
        do {
            return try database.read { db in
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.articleAgeLimitDays).fetchOne(db),
                   let days = Int(setting.value) {
                    return days
                }
                return AppSettings.defaultArticleAgeLimitDays
            }
        } catch {
            return AppSettings.defaultArticleAgeLimitDays
        }
    }

    /// Returns the cutoff date for articles based on the age limit setting.
    private func getArticleCutoffDate() -> Date {
        let ageLimitDays = getArticleAgeLimitDays()
        return Calendar.current.date(byAdding: .day, value: -ageLimitDays, to: Date()) ?? Date()
    }

    @concurrent
    func fetchAllFeeds(sources: [RSSSource], extractService: ContentExtractService) async -> [FetchResult] {
        let cutoffDate = getArticleCutoffDate()

        return await withTaskGroup(of: FetchResult.self, returning: [FetchResult].self) { group in
            for source in sources {
                group.addTask {
                    await fetchFeed(source: source, extractService: extractService, cutoffDate: cutoffDate)
                }
            }

            var results: [FetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    /// Fetch all feeds with streaming updates - calls onResult as each feed completes
    @concurrent
    func fetchAllFeedsStreaming(
        sources: [RSSSource],
        extractService: ContentExtractService,
        onResult: @MainActor @escaping (FetchResult) -> Void
    ) async {
        let cutoffDate = getArticleCutoffDate()

        await withTaskGroup(of: FetchResult.self) { group in
            for source in sources {
                group.addTask {
                    await self.fetchFeed(source: source, extractService: extractService, cutoffDate: cutoffDate)
                }
            }

            for await result in group {
                await onResult(result)
            }
        }
    }

    @concurrent
    private func fetchFeed(source: RSSSource, extractService: ContentExtractService, cutoffDate: Date) async -> FetchResult {
        guard let sourceId = source.id else {
            return FetchResult(
                sourceId: 0,
                sourceName: source.url,
                itemCount: 0,
                error: NSError(domain: "RSSService", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid source ID"])
            )
        }

        guard let url = URL(string: source.url) else {
            return FetchResult(
                sourceId: sourceId,
                sourceName: source.title ?? source.url,
                itemCount: 0,
                error: URLError(.badURL)
            )
        }

        do {
            let (data, _) = try await URLSession.shared.data(from: url)
            let parser = FeedParser(data: data)
            let result = parser.parse()

            switch result {
            case .success(let feed):
                let items = try await processFeed(feed, source: source, extractService: extractService, cutoffDate: cutoffDate)
                return FetchResult(
                    sourceId: sourceId,
                    sourceName: source.title ?? source.url,
                    itemCount: items,
                    error: nil
                )
            case .failure(let error):
                return FetchResult(
                    sourceId: sourceId,
                    sourceName: source.title ?? source.url,
                    itemCount: 0,
                    error: error
                )
            }
        } catch {
            return FetchResult(
                sourceId: sourceId,
                sourceName: source.title ?? source.url,
                itemCount: 0,
                error: error
            )
        }
    }

    private func processFeed(_ feed: Feed, source: RSSSource, extractService: ContentExtractService, cutoffDate: Date) async throws -> Int {
        var itemCount = 0

        switch feed {
        case .rss(let rssFeed):
            if let items = rssFeed.items {
                for item in items {
                    // Skip articles older than the cutoff date
                    if let pubDate = item.pubDate, pubDate < cutoffDate {
                        continue
                    }

                    try await processRSSItem(item, source: source, extractService: extractService)
                    itemCount += 1
                }
            }
        case .atom(let atomFeed):
            if let entries = atomFeed.entries {
                for entry in entries {
                    // Skip articles older than the cutoff date
                    let entryDate = entry.published ?? entry.updated
                    if let pubDate = entryDate, pubDate < cutoffDate {
                        continue
                    }

                    try await processAtomEntry(entry, source: source, extractService: extractService)
                    itemCount += 1
                }
            }
        case .json(let jsonFeed):
            if let items = jsonFeed.items {
                for item in items {
                    // Skip articles older than the cutoff date
                    if let pubDate = item.datePublished, pubDate < cutoffDate {
                        continue
                    }

                    try await processJSONItem(item, source: source, extractService: extractService)
                    itemCount += 1
                }
            }
        }

        return itemCount
    }

    private func processRSSItem(_ item: RSSFeedItem, source: RSSSource, extractService: ContentExtractService) async throws {
        guard let sourceId = source.id else { return }

        let guid = item.guid?.value ?? item.link ?? UUID().uuidString
        let title = item.title ?? "Untitled"
        let rawLink = item.link ?? ""
        let description = item.description

        // Sanitize the URL to fix common malformations
        let link = URLSanitizer.sanitize(rawLink) ?? rawLink

        var fullContent: String?
        var finalLink = link

        // Special case: GitHub repository URLs - fetch raw README.md directly
        if ContentExtractService.isGitHubRepoURL(link) {
            fullContent = await extractService.fetchGitHubReadme(from: link)
            if fullContent != nil {
                logger.debug("Fetched raw README.md for GitHub repo: \(title, privacy: .public)")
            }
        }

        // If not GitHub or README fetch failed, check for content:encoded
        if fullContent == nil || fullContent?.isEmpty == true,
           let contentEncoded = item.content?.contentEncoded, !contentEncoded.isEmpty {
            // Feed provides full content as HTML - convert to Markdown
            fullContent = await extractService.extractContent(from: contentEncoded, url: link)

            // If conversion failed, fall through to URL extraction
            if fullContent == nil || fullContent?.isEmpty == true {
                logger.debug("content:encoded conversion failed, falling back to URL extraction for: \(title, privacy: .public)")
            }
        }

        if (fullContent == nil || fullContent?.isEmpty == true) && needsFullContent(description: description) && !link.isEmpty {
            // No content:encoded, try to extract from the article URL (if allowed)
            let result = await extractService.extractContentWithFinalURL(from: link)
            fullContent = result.content
            // Use the final URL after redirects if available
            if let redirectedURL = result.finalURL {
                finalLink = redirectedURL
            }
        }

        // If extraction failed but we have substantial rss_description, use that as full_content
        if fullContent == nil || fullContent?.isEmpty == true {
            if let desc = description, desc.count >= 200, !desc.hasSuffix("..."), !desc.hasSuffix("…") {
                // Convert HTML description to Markdown if it contains HTML tags
                if desc.contains("<") && desc.contains(">") {
                    fullContent = await extractService.extractContent(from: desc, url: link)
                }
                // Fall back to raw description if conversion failed or wasn't needed
                if fullContent == nil || fullContent?.isEmpty == true {
                    fullContent = desc
                }
                logger.debug("Using RSS description as full content for: \(title, privacy: .public)")
            }
        }

        try upsertFeedItem(
            sourceId: sourceId,
            guid: guid,
            title: title,
            link: finalLink,
            pubDate: item.pubDate,
            rssDescription: description,
            fullContent: fullContent,
            author: item.author
        )
    }

    private func processAtomEntry(_ entry: AtomFeedEntry, source: RSSSource, extractService: ContentExtractService) async throws {
        guard let sourceId = source.id else { return }

        let guid = entry.id ?? entry.links?.first?.attributes?.href ?? UUID().uuidString
        let title = entry.title ?? "Untitled"
        let rawLink = entry.links?.first?.attributes?.href ?? ""
        let description = entry.summary?.value ?? entry.content?.value

        // Sanitize the URL to fix common malformations
        let link = URLSanitizer.sanitize(rawLink) ?? rawLink

        var fullContent: String?
        var finalLink = link

        if needsFullContent(description: description) && !link.isEmpty {
            let result = await extractService.extractContentWithFinalURL(from: link)
            fullContent = result.content
            if let redirectedURL = result.finalURL {
                finalLink = redirectedURL
            }
        }

        // If extraction failed but we have substantial description, use that as full_content
        if fullContent == nil || fullContent?.isEmpty == true {
            if let desc = description, desc.count >= 200, !desc.hasSuffix("..."), !desc.hasSuffix("…") {
                // Convert HTML description to Markdown if it contains HTML tags
                if desc.contains("<") && desc.contains(">") {
                    fullContent = await extractService.extractContent(from: desc, url: link)
                }
                // Fall back to raw description if conversion failed or wasn't needed
                if fullContent == nil || fullContent?.isEmpty == true {
                    fullContent = desc
                }
                logger.debug("Using Atom summary as full content for: \(title, privacy: .public)")
            }
        }

        try upsertFeedItem(
            sourceId: sourceId,
            guid: guid,
            title: title,
            link: finalLink,
            pubDate: entry.published ?? entry.updated,
            rssDescription: description,
            fullContent: fullContent,
            author: entry.authors?.first?.name
        )
    }

    private func processJSONItem(_ item: JSONFeedItem, source: RSSSource, extractService: ContentExtractService) async throws {
        guard let sourceId = source.id else { return }

        let guid = item.id ?? item.url ?? UUID().uuidString
        let title = item.title ?? "Untitled"
        let rawLink = item.url ?? ""
        let description = item.summary ?? item.contentHtml ?? item.contentText

        // Sanitize the URL to fix common malformations
        let link = URLSanitizer.sanitize(rawLink) ?? rawLink

        var fullContent: String?
        var finalLink = link

        if needsFullContent(description: description) && !link.isEmpty {
            let result = await extractService.extractContentWithFinalURL(from: link)
            fullContent = result.content
            if let redirectedURL = result.finalURL {
                finalLink = redirectedURL
            }
        }

        // If extraction failed but we have substantial description, use that as full_content
        if fullContent == nil || fullContent?.isEmpty == true {
            if let desc = description, desc.count >= 200, !desc.hasSuffix("..."), !desc.hasSuffix("…") {
                // Convert HTML description to Markdown if it contains HTML tags
                if desc.contains("<") && desc.contains(">") {
                    fullContent = await extractService.extractContent(from: desc, url: link)
                }
                // Fall back to raw description if conversion failed or wasn't needed
                if fullContent == nil || fullContent?.isEmpty == true {
                    fullContent = desc
                }
                logger.debug("Using JSON feed summary as full content for: \(title, privacy: .public)")
            }
        }

        try upsertFeedItem(
            sourceId: sourceId,
            guid: guid,
            title: title,
            link: finalLink,
            pubDate: item.datePublished,
            rssDescription: description,
            fullContent: fullContent,
            author: item.author?.name
        )
    }

    private func needsFullContent(description: String?) -> Bool {
        guard let description else { return true }

        let trimmed = description.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed.count < 500 { return true }
        if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") { return true }
        if trimmed.localizedStandardContains("read more") || trimmed.localizedStandardContains("continue reading") {
            return true
        }

        return false
    }

    private func upsertFeedItem(
        sourceId: Int64,
        guid: String,
        title: String,
        link: String,
        pubDate: Date?,
        rssDescription: String?,
        fullContent: String?,
        author: String?
    ) throws {
        // Determine the best available content
        let effectiveContent = fullContent ?? rssDescription

        // Check if content is too short or truncated
        if let content = effectiveContent {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed.count < 100 {
                logger.info("Skipping article (content too short: \(trimmed.count) chars): \(title, privacy: .public)")
                return
            }

            if trimmed.hasSuffix("...") || trimmed.hasSuffix("…") {
                logger.info("Skipping article (truncated content ending with ...): \(title, privacy: .public)")
                return
            }
        } else {
            // No content at all
            logger.info("Skipping article (no content): \(title, privacy: .public)")
            return
        }

        try database.write { db in
            try db.execute(
                sql: """
                    INSERT INTO feed_item (source_id, guid, title, link, pub_date, rss_description, full_content, author, fetched_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, unixepoch())
                    ON CONFLICT(source_id, guid) DO UPDATE SET
                        title = excluded.title,
                        link = excluded.link,
                        pub_date = excluded.pub_date,
                        rss_description = excluded.rss_description,
                        full_content = COALESCE(excluded.full_content, feed_item.full_content),
                        author = excluded.author,
                        fetched_at = unixepoch()
                """,
                arguments: [sourceId, guid, title, link, pubDate?.timeIntervalSince1970, rssDescription, fullContent, author]
            )
        }
    }
}
