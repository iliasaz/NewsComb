import SwiftUI

/// A sheet for creating or editing a user role.
struct UserRoleEditorSheet: View {
    @Bindable var viewModel: UserRoleViewModel
    @Environment(\.dismiss) private var dismiss

    private var isEditing: Bool {
        viewModel.editingRole != nil
    }

    private var canSave: Bool {
        !viewModel.editorName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !viewModel.editorPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Role Name", text: $viewModel.editorName)
                        .textContentType(.name)
                } header: {
                    Text("Name")
                } footer: {
                    Text("A short, descriptive name for this role (e.g., \"Tech Analyst\", \"Finance Expert\").")
                }

                Section {
                    TextEditor(text: $viewModel.editorPrompt)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 150)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(.rect(cornerRadius: 8))
                } header: {
                    Text("Prompt")
                } footer: {
                    Text("The prompt that defines this role's persona. This will be prepended to your questions when the role is active.")
                }

                if !samplePrompts.isEmpty {
                    Section("Sample Prompts") {
                        ForEach(samplePrompts, id: \.name) { sample in
                            Button(sample.name) {
                                viewModel.editorPrompt = sample.prompt
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.blue)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isEditing ? "Edit Role" : "New Role")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        viewModel.cancelEditor()
                    }
                }

                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        viewModel.saveEditorRole()
                    }
                    .disabled(!canSave)
                }
            }
        }
        .frame(minWidth: 500, minHeight: 400)
    }

    private var samplePrompts: [(name: String, prompt: String)] {
        [
            (
                "Tech Industry Analyst",
                """
                You are a senior technology industry analyst with deep expertise in cloud computing, AI/ML, \
                and enterprise software. When analyzing information, focus on:
                - Market trends and competitive dynamics
                - Technical architecture implications
                - Business model and revenue impacts
                - Strategic recommendations for enterprise adoption
                Provide balanced, evidence-based analysis with specific examples.
                """
            ),
            (
                "Research Scientist",
                """
                You are a research scientist with expertise in reviewing and synthesizing technical literature. \
                When responding:
                - Emphasize methodology and reproducibility
                - Highlight statistical significance and limitations
                - Connect findings to broader research themes
                - Suggest follow-up experiments and hypotheses
                Use precise, academic language and cite specific evidence from the sources.
                """
            ),
            (
                "Executive Summary Writer",
                """
                You are an executive communications specialist who distills complex information into clear, \
                actionable insights for C-level executives. When responding:
                - Lead with the bottom line / key takeaway
                - Use bullet points for easy scanning
                - Highlight risks and opportunities
                - Include specific recommendations with clear next steps
                Keep responses concise and focused on business impact.
                """
            ),
        ]
    }
}

#Preview {
    UserRoleEditorSheet(viewModel: UserRoleViewModel())
}
