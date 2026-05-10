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
    /// Items loaded so far. Append-only across pages within one source filter;
    /// reset on `loadInitial(...)` or when the source changes.
    var items: [FeedItemDisplay] = []
    /// Populated by `performSearch()` when `searchText` is non-empty. Holds
    /// SQL-matched rows from the *whole* table for the current source — not
    /// the paginated subset. `nil` means no search is active and the view
    /// should display `items`.
    var searchResults: [FeedItemDisplay]?
    /// True only while the very first page is being loaded; flipped off after
    /// the initial fetch so the empty-state and "loading more" indicators can
    /// show independently.
    var isLoading = false
    /// True while a follow-up page is in flight. Drives the spinner row at the
    /// bottom of the list.
    var isLoadingMore = false
    /// Becomes false once a fetch returns fewer than `pageSize` rows — at that
    /// point we've reached the end of the table for the current filter and
    /// further `loadMoreIfNeeded` calls are no-ops.
    var hasMoreItems = true
    var errorMessage: String?
    var searchText: String = ""

    /// True while a search query is in flight. Distinct from `isLoading`
    /// (initial page) and `isLoadingMore` (next page) so the view can show a
    /// search-specific affordance if needed.
    var isSearching = false

    /// Number of rows fetched per page. Small enough that the first page
    /// renders quickly and the prefetch trigger fires while the user is still
    /// scrolling, large enough that we don't re-query for every couple of rows.
    static let pageSize = 50
    /// When the user appears within this many rows of the bottom, we kick off
    /// the next page. Tuned so the next batch is usually ready by the time
    /// they reach it.
    static let prefetchThreshold = 10

    /// nil ⇒ "all articles" view (no source filter); non-nil ⇒ scoped to one
    /// feed. Stored so `loadMoreIfNeeded`, `refresh`, and pagination math
    /// don't have to be re-told the source on every call.
    private(set) var currentSourceId: Int64?

    private let database = Database.current

    /// What the view should render. `searchResults` takes precedence so a
    /// search query reflects matches across the whole table; otherwise we
    /// show the paginated `items`.
    var filteredItems: [FeedItemDisplay] {
        searchResults ?? items
    }

    // MARK: - Public API

    /// Reset pagination and load the first page. Call when entering the view
    /// or switching sources. If `sourceId` matches the currently-loaded source
    /// and we already have items, this is a no-op so navigating back to a feed
    /// doesn't re-issue a query and lose scroll position.
    func loadInitial(forSourceId sourceId: Int64?) {
        if currentSourceId == sourceId, !items.isEmpty {
            return
        }
        currentSourceId = sourceId
        items = []
        searchResults = nil  // a different source's results would be misleading
        hasMoreItems = true
        errorMessage = nil
        loadNextPage(initial: true)
    }

    /// Trigger another page if `currentItem` is within the prefetch window
    /// from the bottom of the loaded list and we haven't yet exhausted the
    /// table. Safe to call from a `.onAppear` on every row — the guards below
    /// keep duplicate fetches from overlapping.
    func loadMoreIfNeeded(currentItem: FeedItemDisplay) {
        guard hasMoreItems, !isLoadingMore, !isLoading else { return }
        guard let index = items.firstIndex(where: { $0.id == currentItem.id }) else { return }
        let triggerIndex = items.count - Self.prefetchThreshold
        if index >= max(0, triggerIndex) {
            loadNextPage(initial: false)
        }
    }

    /// Run a substring search across the whole `feed_item` table for the
    /// current source. When `searchText` is empty, drops `searchResults` so
    /// the view falls back to the paginated `items`.
    ///
    /// Uses SQL `LIKE` (not FTS5) — there's no `feed_item_fts` virtual table
    /// in this schema, and adding one is heavier scope than warranted at
    /// today's row counts. `LIKE` is case-insensitive for ASCII (its default
    /// in SQLite) and fast enough on a few-thousand-row `feed_item` table.
    /// `%`, `_`, and `\` in the user input are escaped so they don't smuggle
    /// in wildcards.
    func performSearch() {
        let trimmed = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = nil
            isSearching = false
            return
        }

        isSearching = true
        defer { isSearching = false }

        let pattern = "%" + escapeForLike(trimmed) + "%"
        let sourceId = currentSourceId

        do {
            let fetched: [(FeedItem, RSSSource?)] = try database.read { db in
                var sql = """
                    SELECT * FROM feed_item
                    WHERE (title LIKE ? ESCAPE '\\' OR full_content LIKE ? ESCAPE '\\')
                    """
                var args: [(any DatabaseValueConvertible)?] = [pattern, pattern]
                if let sourceId {
                    sql += " AND source_id = ?"
                    args.append(sourceId)
                }
                sql += " ORDER BY pub_date DESC, fetched_at DESC LIMIT 500"

                let rows = try FeedItem.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                return try rows.map { item in
                    let source = try RSSSource.filter(RSSSource.Columns.id == item.sourceId).fetchOne(db)
                    return (item, source)
                }
            }

            searchResults = fetched.compactMap { item, source -> FeedItemDisplay? in
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
            errorMessage = "Search failed: \(error.localizedDescription)"
            searchResults = []
        }
    }

    /// Escapes the three SQLite `LIKE` wildcards so a user typing `100%` or
    /// `foo_bar` searches for those literal substrings rather than triggering
    /// pattern matching. Mirrors the `ESCAPE '\'` clause used in the query.
    private func escapeForLike(_ s: String) -> String {
        var out = ""
        out.reserveCapacity(s.count)
        for ch in s {
            switch ch {
            case "\\", "%", "_": out.append("\\")
            default: break
            }
            out.append(ch)
        }
        return out
    }

    /// Pull-to-refresh: reset pagination and reload the first page from the
    /// current source.
    func refresh() async {
        let source = currentSourceId
        currentSourceId = nil  // force loadInitial to re-fetch even if items were stale
        loadInitial(forSourceId: source)
    }

    // MARK: - Back-compat shims

    /// Legacy entry point — kept so any caller still using the old API loads
    /// data correctly. Routes through the paginated flow.
    func loadItems() {
        loadInitial(forSourceId: nil)
    }

    /// Legacy entry point — kept for back-compat with `FeedItemsView.onAppear`.
    func loadItems(forSourceId sourceId: Int64) {
        loadInitial(forSourceId: sourceId)
    }

    // MARK: - Internals

    private func loadNextPage(initial: Bool) {
        if initial {
            isLoading = true
        } else {
            isLoadingMore = true
        }
        defer {
            isLoading = false
            isLoadingMore = false
        }

        let offset = items.count
        let limit = Self.pageSize
        let sourceId = currentSourceId

        do {
            let fetched: [(FeedItem, RSSSource?)] = try database.read { db in
                var request = FeedItem
                    .order(FeedItem.Columns.pubDate.desc, FeedItem.Columns.fetchedAt.desc)
                    .limit(limit, offset: offset)
                if let sourceId {
                    request = FeedItem
                        .filter(FeedItem.Columns.sourceId == sourceId)
                        .order(FeedItem.Columns.pubDate.desc, FeedItem.Columns.fetchedAt.desc)
                        .limit(limit, offset: offset)
                }

                let rows = try request.fetchAll(db)
                return try rows.map { item in
                    let source = try RSSSource.filter(RSSSource.Columns.id == item.sourceId).fetchOne(db)
                    return (item, source)
                }
            }

            let newItems = fetched.compactMap { item, source -> FeedItemDisplay? in
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

            items.append(contentsOf: newItems)
            // A short page means we've drained the table for this filter.
            // Use the raw fetch count, not newItems.count, so a row whose
            // `id` is nil (impossible in practice but defended against above)
            // doesn't incorrectly extend pagination.
            if fetched.count < limit {
                hasMoreItems = false
            }
        } catch {
            errorMessage = "Failed to load items: \(error.localizedDescription)"
            hasMoreItems = false  // bail out of paging on error to avoid retry loops
        }
    }
}
