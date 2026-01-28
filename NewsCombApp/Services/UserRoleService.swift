import Foundation
import GRDB
import OSLog

/// Service for managing user roles (personas with prompts).
struct UserRoleService {
    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "UserRoleService")

    // MARK: - CRUD Operations

    /// Fetches all user roles sorted by name.
    func fetchAll() throws -> [UserRole] {
        try database.read { db in
            try UserRole
                .order(UserRole.Columns.name)
                .fetchAll(db)
        }
    }

    /// Fetches the currently active user role, if any.
    func fetchActive() throws -> UserRole? {
        try database.read { db in
            try UserRole
                .filter(UserRole.Columns.isActive == true)
                .fetchOne(db)
        }
    }

    /// Creates a new user role.
    /// - Parameters:
    ///   - name: The display name for the role
    ///   - prompt: The prompt text to prepend to queries
    /// - Returns: The created role with its assigned ID
    @discardableResult
    func create(name: String, prompt: String) throws -> UserRole {
        var role = UserRole(name: name, prompt: prompt)

        try database.write { db in
            try role.insert(db)
        }

        logger.info("Created user role: \(name, privacy: .public)")
        return role
    }

    /// Updates an existing user role.
    /// - Parameters:
    ///   - role: The role to update (must have an ID)
    func update(_ role: UserRole) throws {
        guard role.id != nil else {
            throw UserRoleError.invalidRole("Role must have an ID to update")
        }

        var updatedRole = role
        updatedRole.updatedAt = Date()

        try database.write { db in
            try updatedRole.update(db)
        }

        logger.info("Updated user role: \(role.name, privacy: .public)")
    }

    /// Deletes a user role.
    /// - Parameter role: The role to delete
    func delete(_ role: UserRole) throws {
        try database.write { db in
            try role.delete(db)
        }

        logger.info("Deleted user role: \(role.name, privacy: .public)")
    }

    /// Deletes a user role by ID.
    /// - Parameter id: The ID of the role to delete
    func delete(id: Int64) throws {
        try database.write { db in
            try UserRole
                .filter(UserRole.Columns.id == id)
                .deleteAll(db)
        }

        logger.info("Deleted user role with ID: \(id)")
    }

    // MARK: - Activation

    /// Sets a role as the active role, deactivating any previously active role.
    /// - Parameter role: The role to activate (pass nil to deactivate all roles)
    func setActive(_ role: UserRole?) throws {
        try database.write { db in
            // Deactivate all roles first
            try db.execute(sql: "UPDATE user_role SET is_active = 0, updated_at = unixepoch()")

            // Activate the specified role if provided
            if let role, let roleId = role.id {
                try db.execute(
                    sql: "UPDATE user_role SET is_active = 1, updated_at = unixepoch() WHERE id = ?",
                    arguments: [roleId]
                )
                logger.info("Activated user role: \(role.name, privacy: .public)")
            } else {
                logger.info("Deactivated all user roles")
            }
        }
    }

    /// Toggles the active state of a role.
    /// If the role is currently active, it will be deactivated.
    /// If the role is not active, it will become the active role.
    /// - Parameter role: The role to toggle
    func toggleActive(_ role: UserRole) throws {
        if role.isActive {
            try setActive(nil)
        } else {
            try setActive(role)
        }
    }
}

// MARK: - Errors

enum UserRoleError: Error, LocalizedError {
    case invalidRole(String)
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .invalidRole(let message):
            return "Invalid role: \(message)"
        case .duplicateName(let name):
            return "A role with the name '\(name)' already exists"
        }
    }
}
