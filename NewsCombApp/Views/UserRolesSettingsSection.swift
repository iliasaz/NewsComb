import SwiftUI

/// A settings section for managing user roles (personas).
struct UserRolesSettingsSection: View {
    @Bindable var viewModel: UserRoleViewModel

    var body: some View {
        Section {
            if viewModel.roles.isEmpty {
                Text("No roles defined")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.roles) { role in
                    UserRoleRow(
                        role: role,
                        onTap: { viewModel.toggleActive(role) },
                        onEdit: { viewModel.presentEditor(for: role) }
                    )
                }
                .onDelete(perform: viewModel.deleteRoles)
            }

            Button("Add Role", systemImage: "plus") {
                viewModel.presentNewRoleEditor()
            }
        } header: {
            Text("User Roles")
        } footer: {
            Text("Define personas with custom prompts that get prepended to your questions. Tap a role to activate it.")
        }
        .sheet(isPresented: $viewModel.isEditorPresented) {
            UserRoleEditorSheet(viewModel: viewModel)
        }
    }
}

/// A row displaying a single user role with active indicator.
struct UserRoleRow: View {
    let role: UserRole
    let onTap: () -> Void
    let onEdit: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text(role.name)
                            .bold()

                        if role.isActive {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                                .imageScale(.small)
                        }
                    }

                    Text(role.prompt)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                Spacer()

                Button("Edit", systemImage: "pencil") {
                    onEdit()
                }
                .buttonStyle(.borderless)
                .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    Form {
        UserRolesSettingsSection(viewModel: UserRoleViewModel())
    }
    .formStyle(.grouped)
}
