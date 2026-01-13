import Foundation
import Observation
import GRDB

/// Represents a feed item with its source information for display
struct FeedItemDisplay: Identifiable, Equatable, Hashable {
    let id: Int64
    let title: String
    let sourceName: String
    let link: String
    let pubDate: Date?
    let rssDescription: String?
    let fullContent: String?
    let author: String?
    let isRead: Bool

    var hasFullContent: Bool {
        fullContent != nil && !fullContent!.isEmpty
    }

    var displayDate: String {
        guard let date = pubDate else { return "" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    var snippet: String {
        let content = rssDescription ?? ""
        let stripped = content.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        let trimmed = stripped.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count > 150 {
            return String(trimmed.prefix(150)) + "..."
        }
        return trimmed
    }
}

@MainActor
@Observable
class FeedItemsViewModel {
    var items: [FeedItemDisplay] = []
    var isLoading = false
    var errorMessage: String?
    var selectedSourceId: Int64?
    var searchText: String = ""

    private let database = Database.shared

    var filteredItems: [FeedItemDisplay] {
        var result = items

        if selectedSourceId != nil {
            // Source filtering is handled by loadItems(forSourceId:)
            // This is a placeholder for future in-memory filtering
        }

        if !searchText.isEmpty {
            result = result.filter { item in
                item.title.localizedStandardContains(searchText) ||
                item.snippet.localizedStandardContains(searchText) ||
                item.sourceName.localizedStandardContains(searchText)
            }
        }

        return result
    }

    func loadItems() {
        isLoading = true
        errorMessage = nil

        do {
            let fetchedItems: [(FeedItem, RSSSource?)] = try database.read { db in
                let request = FeedItem
                    .order(FeedItem.Columns.pubDate.desc, FeedItem.Columns.fetchedAt.desc)
                    .limit(100)

                let items = try request.fetchAll(db)

                return try items.map { item in
                    let source = try RSSSource.filter(RSSSource.Columns.id == item.sourceId).fetchOne(db)
                    return (item, source)
                }
            }

            items = fetchedItems.compactMap { item, source in
                guard let id = item.id else { return nil }
                return FeedItemDisplay(
                    id: id,
                    title: item.title,
                    sourceName: source?.title ?? source?.url ?? "Unknown",
                    link: item.link,
                    pubDate: item.pubDate,
                    rssDescription: item.rssDescription,
                    fullContent: item.fullContent,
                    author: item.author,
                    isRead: false
                )
            }
        } catch {
            errorMessage = "Failed to load items: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func loadItems(forSourceId sourceId: Int64) {
        isLoading = true
        errorMessage = nil

        do {
            let fetchedItems: [(FeedItem, RSSSource?)] = try database.read { db in
                let request = FeedItem
                    .filter(FeedItem.Columns.sourceId == sourceId)
                    .order(FeedItem.Columns.pubDate.desc, FeedItem.Columns.fetchedAt.desc)
                    .limit(100)

                let items = try request.fetchAll(db)

                return try items.map { item in
                    let source = try RSSSource.filter(RSSSource.Columns.id == item.sourceId).fetchOne(db)
                    return (item, source)
                }
            }

            items = fetchedItems.compactMap { item, source in
                guard let id = item.id else { return nil }
                return FeedItemDisplay(
                    id: id,
                    title: item.title,
                    sourceName: source?.title ?? source?.url ?? "Unknown",
                    link: item.link,
                    pubDate: item.pubDate,
                    rssDescription: item.rssDescription,
                    fullContent: item.fullContent,
                    author: item.author,
                    isRead: false
                )
            }
        } catch {
            errorMessage = "Failed to load items: \(error.localizedDescription)"
        }

        isLoading = false
    }

    func refresh() async {
        loadItems()
    }
}
