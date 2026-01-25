import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()

    var body: some View {
        Form {
            feedSettingsSection
            knowledgeExtractionSection
            analysisModelSection
            algorithmParametersSection
            extractionPromptsSection
            deepAnalysisPromptsSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 550, minHeight: 600)
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

    private var analysisModelSection: some View {
        Section {
            Picker("Analysis LLM Provider", selection: $viewModel.analysisLLMProvider) {
                ForEach(AnalysisLLMProviderOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: viewModel.analysisLLMProvider) {
                viewModel.saveAnalysisLLMProvider()
            }

            if viewModel.analysisLLMProvider == .ollama {
                TextField("Ollama Endpoint", text: $viewModel.analysisOllamaEndpoint)
                    .textContentType(.URL)
                    .onChange(of: viewModel.analysisOllamaEndpoint) {
                        viewModel.saveAnalysisOllamaEndpoint()
                    }

                TextField("Analysis Model", text: $viewModel.analysisOllamaModel)
                    .onChange(of: viewModel.analysisOllamaModel) {
                        viewModel.saveAnalysisOllamaModel()
                    }
            }

            if viewModel.analysisLLMProvider == .openrouter {
                TextField("Analysis Model", text: $viewModel.analysisOpenRouterModel)
                    .onChange(of: viewModel.analysisOpenRouterModel) {
                        viewModel.saveAnalysisOpenRouterModel()
                    }
            }
        } header: {
            Text("Analysis Model")
        } footer: {
            Text("Configure a separate LLM for generating answers and deep dive analyses. Uses the same API key as the Chat LLM when using OpenRouter.")
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

            Stepper(value: $viewModel.maxPathDepth, in: 1...8) {
                HStack {
                    Text("Max Path Depth")
                    Spacer()
                    Text("\(viewModel.maxPathDepth) (up to \(viewModel.maxPathDepth + 1) hops)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.maxPathDepth) {
                viewModel.saveMaxPathDepth()
            }

            Divider()

            // Concurrent Processing
            Stepper(value: $viewModel.maxConcurrentProcessing, in: 1...20) {
                HStack {
                    Text("Max Concurrent Articles")
                    Spacer()
                    Text("\(viewModel.maxConcurrentProcessing)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.maxConcurrentProcessing) {
                viewModel.saveMaxConcurrentProcessing()
            }
        } header: {
            Text("Algorithm Parameters")
        } footer: {
            Text("Fine-tune knowledge extraction, node merging, and query parameters.")
        }
    }

    private var extractionPromptsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Extraction System Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        viewModel.resetExtractionPromptToDefault()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                TextEditor(text: $viewModel.extractionSystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .onChange(of: viewModel.extractionSystemPrompt) {
                        viewModel.saveExtractionSystemPrompt()
                    }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Distillation System Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        viewModel.resetDistillationPromptToDefault()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                TextEditor(text: $viewModel.distillationSystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 100)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .onChange(of: viewModel.distillationSystemPrompt) {
                        viewModel.saveDistillationSystemPrompt()
                    }
            }
        } header: {
            Text("Extraction Prompts")
        } footer: {
            Text("Customize the system prompts used for knowledge graph extraction. The extraction prompt instructs the LLM how to extract entities and relationships. The distillation prompt is used for optional text summarization before extraction.")
        }
    }

    private var deepAnalysisPromptsSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Engineer Agent Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        viewModel.resetEngineerAgentPromptToDefault()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                TextEditor(text: $viewModel.engineerAgentPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .onChange(of: viewModel.engineerAgentPrompt) {
                        viewModel.saveEngineerAgentPrompt()
                    }
            }

            Divider()

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Hypothesizer Agent Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        viewModel.resetHypothesizerAgentPromptToDefault()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                TextEditor(text: $viewModel.hypothesizerAgentPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .onChange(of: viewModel.hypothesizerAgentPrompt) {
                        viewModel.saveHypothesizerAgentPrompt()
                    }
            }
        } header: {
            Text("Deep Analysis Agent Prompts")
        } footer: {
            Text("Customize the prompts for the 'Dive Deeper' multi-agent analysis. The Engineer agent synthesizes insights with academic citations. The Hypothesizer agent generates experiments and follow-up questions.")
        }
    }
}

#Preview {
    SettingsView()
}
