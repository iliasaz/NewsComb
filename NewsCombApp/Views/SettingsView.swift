import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            feedSettingsSection
            knowledgeExtractionSection
            algorithmParametersSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 450, minHeight: 400)
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

    private var feedSettingsSection: some View {
        Section {
            Stepper(value: $viewModel.articleAgeLimitDays, in: 1...365) {
                HStack {
                    Text("Article Age Limit")
                    Spacer()
                    Text("\(viewModel.articleAgeLimitDays) day\(viewModel.articleAgeLimitDays == 1 ? "" : "s")")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.articleAgeLimitDays) {
                viewModel.saveArticleAgeLimitDays()
            }
        } header: {
            Text("Feed Settings")
        } footer: {
            Text("Only fetch articles published within the last \(viewModel.articleAgeLimitDays) day\(viewModel.articleAgeLimitDays == 1 ? "" : "s"). Older articles will be skipped.")
        }
    }

    private var knowledgeExtractionSection: some View {
        Section {
            // LLM Provider
            Picker("LLM Provider", selection: $viewModel.llmProvider) {
                ForEach(LLMProviderOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: viewModel.llmProvider) {
                viewModel.saveLLMProvider()
            }

            if viewModel.llmProvider == .ollama {
                TextField("Ollama Endpoint", text: $viewModel.ollamaEndpoint)
                    .textContentType(.URL)
                    .onChange(of: viewModel.ollamaEndpoint) {
                        viewModel.saveOllamaEndpoint()
                    }

                TextField("Chat Model", text: $viewModel.ollamaModel)
                    .onChange(of: viewModel.ollamaModel) {
                        viewModel.saveOllamaModel()
                    }
            }

            if viewModel.llmProvider == .openrouter {
                SecureField("OpenRouter API Key", text: $viewModel.openRouterKey)
                    .textContentType(.password)
                    .onChange(of: viewModel.openRouterKey) {
                        viewModel.saveOpenRouterKey()
                    }

                TextField("Chat Model", text: $viewModel.openRouterModel)
                    .onChange(of: viewModel.openRouterModel) {
                        viewModel.saveOpenRouterModel()
                    }
            }

            Divider()

            // Embedding Provider
            Picker("Embedding Provider", selection: $viewModel.embeddingProvider) {
                ForEach(EmbeddingProviderOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: viewModel.embeddingProvider) {
                viewModel.saveEmbeddingProvider()
            }

            if viewModel.embeddingProvider == .ollama {
                TextField("Embedding Endpoint", text: $viewModel.embeddingOllamaEndpoint)
                    .textContentType(.URL)
                    .onChange(of: viewModel.embeddingOllamaEndpoint) {
                        viewModel.saveEmbeddingOllamaEndpoint()
                    }

                TextField("Embedding Model", text: $viewModel.embeddingOllamaModel)
                    .onChange(of: viewModel.embeddingOllamaModel) {
                        viewModel.saveEmbeddingOllamaModel()
                    }
            }

            if viewModel.embeddingProvider == .openrouter {
                TextField("Embedding Model", text: $viewModel.embeddingOpenRouterModel)
                    .onChange(of: viewModel.embeddingOpenRouterModel) {
                        viewModel.saveEmbeddingOpenRouterModel()
                    }
            }
        } header: {
            Text("Knowledge Extraction")
        } footer: {
            Text("Configure LLM for knowledge extraction and embedding model for semantic search.")
        }
    }

    private var algorithmParametersSection: some View {
        Section {
            // Text Chunking
            Stepper(value: $viewModel.chunkSize, in: 200...2000, step: 100) {
                HStack {
                    Text("Chunk Size")
                    Spacer()
                    Text("\(viewModel.chunkSize) chars")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.chunkSize) {
                viewModel.saveChunkSize()
            }

            Divider()

            // Node Merging
            HStack {
                Text("Similarity Threshold")
                Spacer()
                Text("\(viewModel.similarityThreshold, format: .percent.precision(.fractionLength(0)))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.similarityThreshold, in: 0.5...0.99, step: 0.01)
                .onChange(of: viewModel.similarityThreshold) {
                    viewModel.saveSimilarityThreshold()
                }

            Divider()

            // LLM Parameters
            HStack {
                Text("LLM Temperature")
                Spacer()
                Text("\(viewModel.llmTemperature, format: .number.precision(.fractionLength(1)))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.llmTemperature, in: 0...1, step: 0.1)
                .onChange(of: viewModel.llmTemperature) {
                    viewModel.saveLLMTemperature()
                }

            Stepper(value: $viewModel.llmMaxTokens, in: 256...8192, step: 256) {
                HStack {
                    Text("Max Response Tokens")
                    Spacer()
                    Text("\(viewModel.llmMaxTokens)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.llmMaxTokens) {
                viewModel.saveLLMMaxTokens()
            }

            Divider()

            // RAG Query Parameters
            Stepper(value: $viewModel.ragMaxNodes, in: 1...50) {
                HStack {
                    Text("RAG Max Nodes")
                    Spacer()
                    Text("\(viewModel.ragMaxNodes)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.ragMaxNodes) {
                viewModel.saveRAGMaxNodes()
            }

            Stepper(value: $viewModel.ragMaxChunks, in: 1...20) {
                HStack {
                    Text("RAG Max Chunks")
                    Spacer()
                    Text("\(viewModel.ragMaxChunks)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.ragMaxChunks) {
                viewModel.saveRAGMaxChunks()
            }
        } header: {
            Text("Algorithm Parameters")
        } footer: {
            Text("Fine-tune knowledge extraction, node merging, and query parameters.")
        }
    }

}

#Preview {
    SettingsView()
}
