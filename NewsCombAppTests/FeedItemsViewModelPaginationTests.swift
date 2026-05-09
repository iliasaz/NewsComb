import XCTest
import GRDB
@testable import NewsCombApp

/// Pagination tests for `FeedItemsViewModel`. Subclasses
/// `IsolatedDatabaseTestCase` so each test gets a fresh `Database.current`,
/// matching the project pattern used by services that capture
/// `Database.current` at init time.
@MainActor
final class FeedItemsViewModelPaginationTests: IsolatedDatabaseTestCase {

    /// Seed `count` feed items with monotonically descending pubDates so the
    /// `pubDate DESC` ordering used by the view model produces a deterministic
    /// sequence. Returns the inserted source id.
    private func seedFeed(count: Int) throws -> Int64 {
        return try database.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO rss_source (url, title) VALUES (?, ?)",
                arguments: ["manual:feed:test-\(UUID().uuidString)", "Test Feed"]
            )
            let sourceId = db.lastInsertedRowID

            for i in 0..<count {
                let pubDate = Double(2_000_000_000 - i)  // newer first when i is small
                try db.execute(
                    sql: """
                        INSERT INTO feed_item (source_id, guid, title, link, pub_date, full_content)
                        VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        sourceId,
                        "guid-\(i)",
                        "Item \(String(format: "%04d", i))",
                        "manual:item:\(i)",
                        pubDate,
                        String(repeating: "x", count: 200)
                    ]
                )
            }
            return sourceId
        }
    }

    // MARK: - Initial page

    func testInitialPageLoadsExactlyPageSize() throws {
        let sourceId = try seedFeed(count: FeedItemsViewModel.pageSize * 3)
        let vm = FeedItemsViewModel()

        vm.loadInitial(forSourceId: sourceId)

        XCTAssertEqual(vm.items.count, FeedItemsViewModel.pageSize)
        XCTAssertTrue(vm.hasMoreItems)
        XCTAssertFalse(vm.isLoading)
        // Newest items first (smallest i first because of descending pub_date)
        XCTAssertEqual(vm.items.first?.title, "Item 0000")
    }

    func testInitialPageHandlesShortFeedAndExhausts() throws {
        let total = FeedItemsViewModel.pageSize - 5
        let sourceId = try seedFeed(count: total)
        let vm = FeedItemsViewModel()

        vm.loadInitial(forSourceId: sourceId)

        XCTAssertEqual(vm.items.count, total)
        XCTAssertFalse(vm.hasMoreItems, "Page returning fewer than pageSize must mark exhaustion")
    }

    // MARK: - Pagination

    func testLoadMoreIfNeededAppendsNextPage() throws {
        let sourceId = try seedFeed(count: FeedItemsViewModel.pageSize * 3)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)

        // The "current item" is the last loaded — definitely within the
        // prefetch threshold from the bottom.
        let lastVisible = vm.items.last!
        vm.loadMoreIfNeeded(currentItem: lastVisible)

        XCTAssertEqual(vm.items.count, FeedItemsViewModel.pageSize * 2)
        XCTAssertTrue(vm.hasMoreItems)
        XCTAssertEqual(vm.items.first?.title, "Item 0000", "First page must remain stable")
        XCTAssertEqual(vm.items.last?.title, String(format: "Item %04d", FeedItemsViewModel.pageSize * 2 - 1))
    }

    func testLoadMoreIfNeededIsNoOpWhenItemFarFromEnd() throws {
        let sourceId = try seedFeed(count: FeedItemsViewModel.pageSize * 3)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)

        // Item near the top is well outside the prefetch window — no load.
        let topItem = vm.items.first!
        vm.loadMoreIfNeeded(currentItem: topItem)

        XCTAssertEqual(vm.items.count, FeedItemsViewModel.pageSize)
    }

    func testRepeatedLoadMoreEventuallyExhausts() throws {
        let total = FeedItemsViewModel.pageSize * 2 + 7  // not a clean multiple
        let sourceId = try seedFeed(count: total)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)

        // Drive pagination via the public API until exhausted.
        var safety = 10
        while vm.hasMoreItems && safety > 0 {
            vm.loadMoreIfNeeded(currentItem: vm.items.last!)
            safety -= 1
        }

        XCTAssertGreaterThan(safety, 0, "Pagination should exhaust without hitting safety counter")
        XCTAssertEqual(vm.items.count, total, "All seeded rows must be reachable through pagination")
        XCTAssertFalse(vm.hasMoreItems)
    }

    // MARK: - Source filter

    func testPaginationRespectsSourceFilter() throws {
        let _ = try seedFeed(count: 10)  // unrelated feed
        let target = try seedFeed(count: 12)
        let vm = FeedItemsViewModel()

        vm.loadInitial(forSourceId: target)

        XCTAssertEqual(vm.items.count, 12)
        XCTAssertFalse(vm.hasMoreItems)
        XCTAssertEqual(vm.items.first?.title, "Item 0000")
    }

    func testLoadInitialSwitchingSourceResetsState() throws {
        let s1 = try seedFeed(count: 8)
        let s2 = try seedFeed(count: 5)
        let vm = FeedItemsViewModel()

        vm.loadInitial(forSourceId: s1)
        XCTAssertEqual(vm.items.count, 8)

        vm.loadInitial(forSourceId: s2)
        XCTAssertEqual(vm.items.count, 5, "Switching source must replace, not append")
        XCTAssertEqual(vm.currentSourceId, s2)
    }

    func testLoadInitialIsIdempotentForSameSource() throws {
        let sourceId = try seedFeed(count: FeedItemsViewModel.pageSize * 3)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)
        vm.loadMoreIfNeeded(currentItem: vm.items.last!)
        let countAfterTwoPages = vm.items.count

        // Calling loadInitial again with the same source while items are
        // already loaded must NOT re-fetch — preserves scroll position when
        // the user navigates away and back.
        vm.loadInitial(forSourceId: sourceId)
        XCTAssertEqual(vm.items.count, countAfterTwoPages)
    }

    // MARK: - Refresh

    func testRefreshResetsAndReloadsCurrentSource() async throws {
        let sourceId = try seedFeed(count: FeedItemsViewModel.pageSize * 2)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)
        vm.loadMoreIfNeeded(currentItem: vm.items.last!)
        XCTAssertEqual(vm.items.count, FeedItemsViewModel.pageSize * 2)

        await vm.refresh()

        // After refresh, only the first page is loaded again, scoped to
        // the same source.
        XCTAssertEqual(vm.items.count, FeedItemsViewModel.pageSize)
        XCTAssertEqual(vm.currentSourceId, sourceId)
        XCTAssertTrue(vm.hasMoreItems)
    }

    // MARK: - All-articles view

    func testNilSourceLoadsAcrossAllSources() throws {
        _ = try seedFeed(count: 4)
        _ = try seedFeed(count: 3)
        let vm = FeedItemsViewModel()

        vm.loadInitial(forSourceId: nil)

        XCTAssertEqual(vm.items.count, 7, "Across all sources must aggregate")
        XCTAssertNil(vm.currentSourceId)
    }

    // MARK: - Search

    func testSearchFindsRowsBeyondLoadedPages() throws {
        // 200 items, page size 50. Without SQL search, "Item 0150" would be
        // unreachable from the search box because it's never paged in.
        let sourceId = try seedFeed(count: 200)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)
        XCTAssertEqual(vm.items.count, FeedItemsViewModel.pageSize, "Only first page should be loaded")

        vm.searchText = "Item 0150"
        vm.performSearch()

        XCTAssertEqual(vm.items.count, FeedItemsViewModel.pageSize, "Search must not mutate the paginated items list")
        XCTAssertEqual(vm.filteredItems.count, 1, "Search must reach across the whole table, not just loaded pages")
        XCTAssertEqual(vm.filteredItems.first?.title, "Item 0150")
    }

    func testSearchHitsFullContentSubstrings() throws {
        let sourceId = try database.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO rss_source (url, title) VALUES (?, ?)",
                arguments: ["manual:feed:content-test", "Content Test"]
            )
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO feed_item (source_id, guid, title, link, pub_date, full_content)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, "g1", "alpha.swift", "manual:item:1", 1.0,
                            "func magicTokenXYZ() {}"]
            )
            try db.execute(
                sql: """
                    INSERT INTO feed_item (source_id, guid, title, link, pub_date, full_content)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, "g2", "beta.swift", "manual:item:2", 2.0,
                            "let unrelated = 1"]
            )
            return id
        }

        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)
        vm.searchText = "magicTokenXYZ"
        vm.performSearch()

        XCTAssertEqual(vm.filteredItems.count, 1)
        XCTAssertEqual(vm.filteredItems.first?.title, "alpha.swift",
                       "Search must hit full_content, not just title")
    }

    func testClearingSearchRestoresPaginatedItems() throws {
        let sourceId = try seedFeed(count: 200)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)
        vm.loadMoreIfNeeded(currentItem: vm.items.last!)
        let loadedCount = vm.items.count

        vm.searchText = "Item 0150"
        vm.performSearch()
        XCTAssertNotNil(vm.searchResults)

        vm.searchText = ""
        vm.performSearch()

        XCTAssertNil(vm.searchResults, "Empty search must drop the result override")
        XCTAssertEqual(vm.filteredItems.count, loadedCount,
                       "Clearing search must reveal the previously paginated items, not reset them")
    }

    func testSearchEscapesLikeWildcards() throws {
        let sourceId = try database.write { db -> Int64 in
            try db.execute(
                sql: "INSERT INTO rss_source (url, title) VALUES (?, ?)",
                arguments: ["manual:feed:wildcard-test", "Wildcard Test"]
            )
            let id = db.lastInsertedRowID
            try db.execute(
                sql: """
                    INSERT INTO feed_item (source_id, guid, title, link, pub_date, full_content)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, "g1", "literal_match.txt", "manual:item:1", 1.0, String(repeating: "x", count: 200)]
            )
            try db.execute(
                sql: """
                    INSERT INTO feed_item (source_id, guid, title, link, pub_date, full_content)
                    VALUES (?, ?, ?, ?, ?, ?)
                """,
                arguments: [id, "g2", "literalAmatch.txt", "manual:item:2", 2.0, String(repeating: "x", count: 200)]
            )
            return id
        }

        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: sourceId)

        // The literal `_` in the user query must NOT match `A` (the SQL
        // wildcard semantics) — should only match the file with an actual
        // underscore.
        vm.searchText = "literal_match"
        vm.performSearch()

        XCTAssertEqual(vm.filteredItems.count, 1)
        XCTAssertEqual(vm.filteredItems.first?.title, "literal_match.txt")
    }

    func testSearchRespectsSourceFilter() throws {
        let s1 = try seedFeed(count: 10)
        let s2 = try seedFeed(count: 10)
        let vm = FeedItemsViewModel()
        vm.loadInitial(forSourceId: s1)

        vm.searchText = "Item 0003"
        vm.performSearch()

        XCTAssertEqual(vm.filteredItems.count, 1, "Only source s1 should match")
        // Verify by switching to all-articles, where two items match:
        vm.loadInitial(forSourceId: nil)
        vm.searchText = "Item 0003"
        vm.performSearch()
        XCTAssertEqual(vm.filteredItems.count, 2, "Across all sources, both feeds match")
        _ = s2
    }
}
