import Testing
import Foundation
@testable import NewsComb

struct ModelsTests {
    @Test
    func rssSourceEquatable() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let source1 = RSSSource(id: 1, url: "https://example.com/feed", createdAt: fixedDate)
        let source2 = RSSSource(id: 1, url: "https://example.com/feed", createdAt: fixedDate)
        let source3 = RSSSource(id: 2, url: "https://example.com/feed", createdAt: fixedDate)

        #expect(source1 == source2)
        #expect(source1 != source3)
    }

    @Test
    func feedItemEquatable() {
        let fixedDate = Date(timeIntervalSince1970: 1000)
        let item1 = FeedItem(
            id: 1,
            sourceId: 1,
            guid: "guid-1",
            title: "Test",
            link: "https://example.com",
            fetchedAt: fixedDate
        )
        let item2 = FeedItem(
            id: 1,
            sourceId: 1,
            guid: "guid-1",
            title: "Test",
            link: "https://example.com",
            fetchedAt: fixedDate
        )

        #expect(item1 == item2)
    }

    @Test
    func appSettingsKeys() {
        #expect(AppSettings.feedbinUsername == "feedbin_username")
        #expect(AppSettings.feedbinSecret == "feedbin_secret")
        #expect(AppSettings.openRouterKey == "openrouter_key")
    }
}
