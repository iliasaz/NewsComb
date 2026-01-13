import Foundation
@preconcurrency import FeedKit
import GRDB

struct FetchResult: Sendable {
    let sourceId: Int64
    let sourceName: String
    let itemCount: Int
    let error: Error?
}

struct RSSService {
    private let database = Database.shared

    @concurrent
    func fetchAllFeeds(sources: [RSSSource], extractService: ContentExtractService) async -> [FetchResult] {
        await withTaskGroup(of: FetchResult.self, returning: [FetchResult].self) { group in
            for source in sources {
                group.addTask {
                    await fetchFeed(source: source, extractService: extractService)
                }
            }

            var results: [FetchResult] = []
            for await result in group {
                results.append(result)
            }
            return results
        }
    }

    @concurrent
    private func fetchFeed(source: RSSSource, extractService: ContentExtractService) async -> FetchResult {
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
                let items = try await processFeed(feed, source: source, extractService: extractService)
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

    private func processFeed(_ feed: Feed, source: RSSSource, extractService: ContentExtractService) async throws -> Int {
        var itemCount = 0

        switch feed {
        case .rss(let rssFeed):
            if let items = rssFeed.items {
                for item in items {
                    try await processRSSItem(item, source: source, extractService: extractService)
                    itemCount += 1
                }
            }
        case .atom(let atomFeed):
            if let entries = atomFeed.entries {
                for entry in entries {
                    try await processAtomEntry(entry, source: source, extractService: extractService)
                    itemCount += 1
                }
            }
        case .json(let jsonFeed):
            if let items = jsonFeed.items {
                for item in items {
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
        let link = item.link ?? ""
        let description = item.description

        var fullContent: String?
        if needsFullContent(description: description) && !link.isEmpty {
            fullContent = await extractService.extractContent(from: link)
        }

        try upsertFeedItem(
            sourceId: sourceId,
            guid: guid,
            title: title,
            link: link,
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
        let link = entry.links?.first?.attributes?.href ?? ""
        let description = entry.summary?.value ?? entry.content?.value

        var fullContent: String?
        if needsFullContent(description: description) && !link.isEmpty {
            fullContent = await extractService.extractContent(from: link)
        }

        try upsertFeedItem(
            sourceId: sourceId,
            guid: guid,
            title: title,
            link: link,
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
        let link = item.url ?? ""
        let description = item.summary ?? item.contentHtml ?? item.contentText

        var fullContent: String?
        if needsFullContent(description: description) && !link.isEmpty {
            fullContent = await extractService.extractContent(from: link)
        }

        try upsertFeedItem(
            sourceId: sourceId,
            guid: guid,
            title: title,
            link: link,
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
