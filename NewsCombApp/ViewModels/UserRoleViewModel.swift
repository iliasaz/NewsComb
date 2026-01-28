import Foundation
import OSLog

/// ViewModel for managing user roles in the settings UI.
@MainActor
@Observable
final class UserRoleViewModel {
    // MARK: - Published State

    var roles: [UserRole] = []
    var errorMessage: String?

    /// The role currently being edited (nil for new role)
    var editingRole: UserRole?

    /// Whether the editor sheet is showing
    var isEditorPresented = false

    // MARK: - Editor State

    var editorName = ""
    var editorPrompt = ""

    // MARK: - Services

    private let userRoleService = UserRoleService()
    private let logger = Logger(subsystem: "com.newscomb", category: "UserRoleViewModel")

    // MARK: - Data Loading

    /// Loads all user roles from the database.
    func loadRoles() {
        do {
            roles = try userRoleService.fetchAll()
        } catch {
            logger.error("Failed to load user roles: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to load roles: \(error.localizedDescription)"
        }
    }

    /// Returns the currently active role, if any.
    var activeRole: UserRole? {
        roles.first { $0.isActive }
    }

    // MARK: - Editor Actions

    /// Opens the editor to create a new role.
    func presentNewRoleEditor() {
        editingRole = nil
        editorName = ""
        editorPrompt = ""
        isEditorPresented = true
    }

    /// Opens the editor to edit an existing role.
    func presentEditor(for role: UserRole) {
        editingRole = role
        editorName = role.name
        editorPrompt = role.prompt
        isEditorPresented = true
    }

    /// Saves the role from the editor (creates new or updates existing).
    func saveEditorRole() {
        let trimmedName = editorName.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPrompt = editorPrompt.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessage = "Role name cannot be empty"
            return
        }

        guard !trimmedPrompt.isEmpty else {
            errorMessage = "Role prompt cannot be empty"
            return
        }

        do {
            if var existingRole = editingRole {
                // Update existing role
                existingRole.name = trimmedName
                existingRole.prompt = trimmedPrompt
                try userRoleService.update(existingRole)
            } else {
                // Create new role
                try userRoleService.create(name: trimmedName, prompt: trimmedPrompt)
            }

            isEditorPresented = false
            loadRoles()
        } catch {
            logger.error("Failed to save role: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to save role: \(error.localizedDescription)"
        }
    }

    /// Cancels the editor without saving.
    func cancelEditor() {
        isEditorPresented = false
        editingRole = nil
        editorName = ""
        editorPrompt = ""
    }

    // MARK: - Role Actions

    /// Toggles whether a role is active.
    func toggleActive(_ role: UserRole) {
        do {
            try userRoleService.toggleActive(role)
            loadRoles()
        } catch {
            logger.error("Failed to toggle role: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to toggle role: \(error.localizedDescription)"
        }
    }

    /// Deletes a role.
    func deleteRole(_ role: UserRole) {
        do {
            try userRoleService.delete(role)
            loadRoles()
        } catch {
            logger.error("Failed to delete role: \(error.localizedDescription, privacy: .public)")
            errorMessage = "Failed to delete role: \(error.localizedDescription)"
        }
    }

    /// Deletes roles at the given offsets.
    func deleteRoles(at offsets: IndexSet) {
        for index in offsets {
            deleteRole(roles[index])
        }
    }
}
