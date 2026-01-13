import Foundation
import GRDB

struct RSSSource: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var url: String
    var title: String?
    var createdAt: Date

    static let databaseTableName = "rss_source"

    enum CodingKeys: String, CodingKey {
        case id, url, title
        case createdAt = "created_at"
    }

    enum Columns: String, ColumnExpression {
        case id, url, title, createdAt = "created_at"
    }

    init(id: Int64? = nil, url: String, title: String? = nil, createdAt: Date = Date()) {
        self.id = id
        self.url = url
        self.title = title
        self.createdAt = createdAt
    }
}
