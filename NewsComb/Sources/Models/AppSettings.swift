import Foundation
import GRDB

struct AppSettings: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var key: String
    var value: String

    static let databaseTableName = "app_settings"

    enum Columns: String, ColumnExpression {
        case id, key, value
    }

    init(id: Int64? = nil, key: String, value: String) {
        self.id = id
        self.key = key
        self.value = value
    }
}

extension AppSettings {
    static let feedbinUsername = "feedbin_username"
    static let feedbinSecret = "feedbin_secret"
    static let openRouterKey = "openrouter_key"
    static let graphNodeColor = "graph_node_color"
    static let defaultGraphNodeColor = "808080"
}
