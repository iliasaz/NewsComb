import Foundation
import GRDB

/// A user-defined role that provides a persona/prompt to prepend to LLM queries.
/// Only one role can be active at a time.
struct UserRole: Identifiable, Equatable, Codable, FetchableRecord, PersistableRecord {
    var id: Int64?
    var name: String
    var prompt: String
    var isActive: Bool
    var createdAt: Date
    var updatedAt: Date

    static let databaseTableName = "user_role"

    enum CodingKeys: String, CodingKey {
        case id, name, prompt
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    enum Columns: String, ColumnExpression {
        case id, name, prompt
        case isActive = "is_active"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
    }

    init(
        id: Int64? = nil,
        name: String,
        prompt: String,
        isActive: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.isActive = isActive
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
