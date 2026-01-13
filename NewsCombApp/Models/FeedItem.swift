import Foundation
import GRDB

struct FeedItem: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var sourceId: Int64
    var guid: String
    var title: String
    var link: String
    var pubDate: Date?
    var rssDescription: String?
    var fullContent: String?
    var author: String?
    var fetchedAt: Date

    static let databaseTableName = "feed_item"

    enum CodingKeys: String, CodingKey {
        case id, guid, title, link, author
        case sourceId = "source_id"
        case pubDate = "pub_date"
        case rssDescription = "rss_description"
        case fullContent = "full_content"
        case fetchedAt = "fetched_at"
    }

    enum Columns: String, ColumnExpression {
        case id, sourceId = "source_id", guid, title, link
        case pubDate = "pub_date", rssDescription = "rss_description"
        case fullContent = "full_content", author, fetchedAt = "fetched_at"
    }

    init(
        id: Int64? = nil,
        sourceId: Int64,
        guid: String,
        title: String,
        link: String,
        pubDate: Date? = nil,
        rssDescription: String? = nil,
        fullContent: String? = nil,
        author: String? = nil,
        fetchedAt: Date = Date()
    ) {
        self.id = id
        self.sourceId = sourceId
        self.guid = guid
        self.title = title
        self.link = link
        self.pubDate = pubDate
        self.rssDescription = rssDescription
        self.fullContent = fullContent
        self.author = author
        self.fetchedAt = fetchedAt
    }
}
