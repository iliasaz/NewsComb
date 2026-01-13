import SwiftUI
#if canImport(AppKit)
import AppKit
#endif

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        NavigationStack {
            Form {
                rssSourcesSection
                apiKeysSection
            }
            .navigationTitle("Settings")
            .onAppear {
                viewModel.loadData()
            }
            .alert("Error", isPresented: .init(
                get: { viewModel.errorMessage != nil },
                set: { if !$0 { viewModel.errorMessage = nil } }
            )) {
                Button("OK") { viewModel.errorMessage = nil }
            } message: {
                if let error = viewModel.errorMessage {
                    Text(error)
                }
            }
        }
    }

    private var rssSourcesSection: some View {
        Section {
            ForEach(viewModel.rssSources) { source in
                VStack(alignment: .leading) {
                    if let title = source.title {
                        Text(title)
                            .bold()
                    }
                    Text(source.url)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .onDelete(perform: viewModel.deleteSource)

            HStack {
                TextField("RSS Feed URL", text: $viewModel.newSourceURL)
                    .textContentType(.URL)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif

                Button("Add", systemImage: "plus") {
                    viewModel.addSource()
                }
                .disabled(viewModel.newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            Button("Paste from Clipboard", systemImage: "doc.on.clipboard") {
                pasteFromClipboard()
            }
        } header: {
            Text("RSS Sources")
        } footer: {
            Text("Add RSS feed URLs individually or paste multiple URLs from clipboard (one per line or comma-separated).")
        }
    }

    private func pasteFromClipboard() {
        #if canImport(AppKit)
        if let string = NSPasteboard.general.string(forType: .string) {
            viewModel.pasteMultipleSources(string)
        }
        #else
        if let string = UIPasteboard.general.string {
            viewModel.pasteMultipleSources(string)
        }
        #endif
    }

    private var apiKeysSection: some View {
        Section {
            SecureField("Feedbin Username", text: $viewModel.feedbinUsername)
                .textContentType(.username)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                #endif
                .onChange(of: viewModel.feedbinUsername) {
                    viewModel.saveFeedbinUsername()
                }

            SecureField("Feedbin Secret Key", text: $viewModel.feedbinSecret)
                .textContentType(.password)
                .onChange(of: viewModel.feedbinSecret) {
                    viewModel.saveFeedbinSecret()
                }

            SecureField("OpenRouter API Key", text: $viewModel.openRouterKey)
                .textContentType(.password)
                .onChange(of: viewModel.openRouterKey) {
                    viewModel.saveOpenRouterKey()
                }
        } header: {
            Text("API Keys")
        } footer: {
            Text("Feedbin credentials are used for article extraction. OpenRouter is used for AI-powered summarization.")
        }
    }
}

#Preview {
    SettingsView()
}
