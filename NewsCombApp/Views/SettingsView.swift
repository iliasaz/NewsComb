import SwiftUI

struct SettingsView: View {
    @State private var viewModel = SettingsViewModel()
    @State private var userRoleViewModel = UserRoleViewModel()

    var body: some View {
        Form {
            #if os(macOS)
            WorkspaceSettingsSection(coordinator: WorkspaceCoordinator.shared)
            #endif
            feedSettingsSection
            userRolesSection
            knowledgeExtractionSection
            analysisModelSection
            algorithmParametersSection
            clusterLabelingPromptSection
            extractionPromptsSection
            deepAnalysisPromptsSection
            socialSimulationSection
        }
        .formStyle(.grouped)
        .frame(minWidth: 550, minHeight: 600)
        .onAppear {
            viewModel.loadData()
            userRoleViewModel.loadRoles()
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

    private var userRolesSection: some View {
        UserRolesSettingsSection(viewModel: userRoleViewModel)
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

            HStack {
                Text("Seed Default Tech Feeds")
                Spacer()
                Button("Add Default Feeds", systemImage: "plus.rectangle.on.folder") {
                    viewModel.seedDefaultFeeds()
                }
            }
        } header: {
            Text("Feed Settings")
        } footer: {
            Text("Only fetch articles published within the last \(viewModel.articleAgeLimitDays) day\(viewModel.articleAgeLimitDays == 1 ? "" : "s"). Older articles will be skipped. Use \"Add Default Feeds\" to insert a curated set of cloud, AI, and tech-news feeds — already-present URLs are skipped.")
        }
        .alert("Default Feeds", isPresented: .init(
            get: { viewModel.seedFeedsResultMessage != nil },
            set: { if !$0 { viewModel.seedFeedsResultMessage = nil } }
        )) {
            Button("OK") { viewModel.seedFeedsResultMessage = nil }
        } message: {
            if let message = viewModel.seedFeedsResultMessage {
                Text(message)
            }
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
                if viewModel.llmProvider == .onDevice {
                    viewModel.refreshOnDeviceAvailability()
                }
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

            if viewModel.llmProvider == .onDevice {
                LabeledContent("Model Status", value: viewModel.onDeviceAvailabilityStatus)
                    .foregroundStyle(.secondary)

                Stepper(value: $viewModel.onDeviceChunkSize, in: 200...1200, step: 100) {
                    HStack {
                        Text("Chunk Size")
                        Spacer()
                        Text("\(viewModel.onDeviceChunkSize)")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: viewModel.onDeviceChunkSize) {
                    viewModel.saveOnDeviceChunkSize()
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

            if viewModel.embeddingProvider == .nomic {
                LabeledContent("Embedding Model", value: NomicEmbeddingService.modelName)
                    .foregroundStyle(.secondary)
                LabeledContent("Embedding Dimensions", value: "\(NomicEmbeddingService.embeddingDimension)")
                    .foregroundStyle(.secondary)
            }

            if viewModel.embeddingProvider == .openrouter {
                TextField("Embedding Model", text: $viewModel.embeddingOpenRouterModel)
                    .onChange(of: viewModel.embeddingOpenRouterModel) {
                        viewModel.saveEmbeddingOpenRouterModel()
                    }

                Stepper(value: $viewModel.embeddingDimension, in: 256...AppSettings.maxEmbeddingDimension, step: 256) {
                    HStack {
                        Text("Embedding Dimensions")
                        Spacer()
                        Text("\(viewModel.embeddingDimension)")
                            .foregroundStyle(.secondary)
                    }
                }
                .onChange(of: viewModel.embeddingDimension) {
                    viewModel.saveEmbeddingDimension()
                }
            }

            if viewModel.needsGraphRebuild {
                Label(
                    "Embedding dimensions have changed. Reset the knowledge graph before processing new articles.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .foregroundStyle(.orange)
            }
        } header: {
            Text("Knowledge Extraction")
        } footer: {
            if viewModel.embeddingProvider == .nomic {
                Text("Configure LLM for knowledge extraction. Nomic Embed Text v1.5 runs on-device via MLTensor (768-d vectors). Switching providers requires a knowledge graph reset.")
            } else {
                Text("Configure LLM for knowledge extraction and embedding model for semantic search. Changing the embedding dimension requires a knowledge graph reset.")
            }
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

            // Dimensionality Reduction (PCA + UMAP)
            Text("Dimensionality Reduction")
                .font(.headline)

            Stepper(value: $viewModel.pcaIntermediateDimension, in: 10...200, step: 10) {
                HStack {
                    Text("PCA Intermediate Dim")
                    Spacer()
                    Text("\(viewModel.pcaIntermediateDimension)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.pcaIntermediateDimension) {
                viewModel.savePCAIntermediateDimension()
            }

            Stepper(value: $viewModel.umapTargetDimension, in: 5...100, step: 5) {
                HStack {
                    Text("UMAP Target Dim")
                    Spacer()
                    Text("\(viewModel.umapTargetDimension)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.umapTargetDimension) {
                viewModel.saveUMAPTargetDimension()
            }

            Stepper(value: $viewModel.umapNNeighbors, in: 5...50) {
                HStack {
                    Text("UMAP Neighbors")
                    Spacer()
                    Text("\(viewModel.umapNNeighbors)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.umapNNeighbors) {
                viewModel.saveUMAPNNeighbors()
            }

            Divider()

            // HDBSCAN Clustering
            Text("HDBSCAN Clustering")
                .font(.headline)

            Stepper(value: $viewModel.hdbscanMinClusterSize, in: 0...500, step: 5) {
                HStack {
                    Text("Min Cluster Size")
                    ParameterInfoButton(
                        title: "HDBSCAN Min Cluster Size",
                        description: """
                            Smallest group of events that HDBSCAN will treat as a real cluster. Anything smaller is merged into a parent cluster or marked as noise.

                            • 0 (Auto) — scales as max(20, √N / 2). Conservative; tends to produce a few giant catch-all clusters on large datasets.
                            • Higher (100–300) — forces fewer, broader themes. Use when one mega-cluster is absorbing unrelated content.
                            • Lower (10–20) — allows many small, specific themes. Risk: noisy fragmentation.

                            A safety floor inside HDBSCANService prevents pathological values regardless of what you set here.
                            """
                    )
                    Spacer()
                    Text(viewModel.hdbscanMinClusterSize == 0 ? "Auto" : "\(viewModel.hdbscanMinClusterSize)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.hdbscanMinClusterSize) {
                viewModel.saveHDBSCANMinClusterSize()
            }

            Stepper(value: $viewModel.hdbscanMinSamples, in: 2...50) {
                HStack {
                    Text("Min Samples")
                    ParameterInfoButton(
                        title: "HDBSCAN Min Samples",
                        description: """
                            Number of nearest neighbors used to compute each point's *core distance* — the local density estimate at that point.

                            Higher values make HDBSCAN more conservative: fewer, denser clusters with more noise. Typical: 5–20.

                            Clamped to ≤ Min Cluster Size; values above that have no effect.
                            """
                    )
                    Spacer()
                    Text("\(viewModel.hdbscanMinSamples)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.hdbscanMinSamples) {
                viewModel.saveHDBSCANMinSamples()
            }

            HStack {
                Text("Merge Similarity Threshold")
                ParameterInfoButton(
                    title: "Cluster Merge Similarity Threshold",
                    description: """
                        After HDBSCAN, similar clusters are merged when their centroids' cosine similarity exceeds this value.

                        • Default 0.85 — only very close themes are merged.
                        • Lower (e.g. 0.75) — consolidates more aggressively.
                        • Higher (e.g. 0.95) — keeps nuanced sub-themes separate.
                        """
                )
                Spacer()
                Text(viewModel.clusterMergeThreshold, format: .percent.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.clusterMergeThreshold, in: 0.5...0.99, step: 0.01)
                .onChange(of: viewModel.clusterMergeThreshold) {
                    viewModel.saveClusterMergeThreshold()
                }

            HStack {
                Text("Noise-Pool IQR Multiplier")
                ParameterInfoButton(
                    title: "Noise-Pool IQR Multiplier",
                    description: """
                        After clustering, top-level cluster sizes are run through an Interquartile Range (IQR) outlier rule on log(size). Any cluster with log(size) above Q3 + multiplier × IQR is flagged as a noise pool — a giant absorption bucket that's not a real theme.

                        • Default 1.5 — standard Tukey rule, flags clear outliers.
                        • Higher (2.0–3.0) — stricter; flags only the most extreme giants.
                        • Lower (1.0) — more aggressive; flags more moderately-large clusters.

                        Flagged noise pools display a badge in the themes list. Use the toolbar action to drop them; underlying graph data is preserved.
                        """
                )
                Spacer()
                Text(viewModel.noisePoolIQRMultiplier, format: .number.precision(.fractionLength(1)))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.noisePoolIQRMultiplier, in: 1.0...3.0, step: 0.1)
                .onChange(of: viewModel.noisePoolIQRMultiplier) {
                    viewModel.saveNoisePoolIQRMultiplier()
                }

            Divider()

            // LLM Parameters
            HStack {
                Text("Extraction Temperature")
                Spacer()
                Text("\(viewModel.extractionTemperature, format: .number.precision(.fractionLength(2)))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.extractionTemperature, in: 0...1, step: 0.05)
                .onChange(of: viewModel.extractionTemperature) {
                    viewModel.saveExtractionTemperature()
                }

            HStack {
                Text("Analysis Temperature")
                Spacer()
                Text("\(viewModel.analysisTemperature, format: .number.precision(.fractionLength(2)))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.analysisTemperature, in: 0...1, step: 0.05)
                .onChange(of: viewModel.analysisTemperature) {
                    viewModel.saveAnalysisTemperature()
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

    private var clusterLabelingPromptSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Cluster Labeling Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        viewModel.resetClusterLabelingPromptToDefault()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                TextEditor(text: $viewModel.clusterLabelingSystemPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 160)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .onChange(of: viewModel.clusterLabelingSystemPrompt) {
                        viewModel.saveClusterLabelingSystemPrompt()
                    }
            }
        } header: {
            Text("Theme Clustering")
        } footer: {
            Text("Used by the analysis LLM at the end of theme clustering to give each cluster a title and one-paragraph summary. Edit for non-news corpora (docs, codebases, scientific or legal text) where the news framing produces awkward labels.")
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

                Toggle("Enable distillation pre-processing", isOn: $viewModel.distillationEnabled)
                    .onChange(of: viewModel.distillationEnabled) {
                        viewModel.saveDistillationEnabled()
                    }

                Text("When on, each chunk runs an extra LLM call to strip marketing fluff and bylines before entity extraction. Doubles the LLM cost per chunk; useful for noisy sources.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

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
    private var socialSimulationSection: some View {
        Section {
            // Environment Status
            Button("Check Environment", systemImage: "arrow.triangle.2.circlepath") {
                Task { await viewModel.checkOasisEnvironment() }
            }
            .disabled(viewModel.isCheckingEnvironment)

            LabeledContent("Python") {
                if viewModel.isCheckingEnvironment {
                    ProgressView()
                        .controlSize(.small)
                } else if viewModel.simPythonDetectedPath.isEmpty || viewModel.simPythonDetectedPath == "Not found" {
                    Text(viewModel.simPythonDetectedPath.isEmpty ? "Not checked" : "Not found")
                        .foregroundStyle(.secondary)
                } else {
                    Text(viewModel.simPythonDetectedPath)
                        .foregroundStyle(.green)
                }
            }

            LabeledContent("OASIS") {
                if viewModel.isCheckingEnvironment {
                    ProgressView()
                        .controlSize(.small)
                } else if viewModel.simOasisInstalled {
                    Text(viewModel.simOasisStatusText)
                        .foregroundStyle(.green)
                } else {
                    Text(viewModel.simOasisStatusText)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            // Simulation Defaults
            Stepper(value: $viewModel.simDefaultMaxRounds, in: 5...500) {
                HStack {
                    Text("Default Max Rounds")
                    Spacer()
                    Text("\(viewModel.simDefaultMaxRounds)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.simDefaultMaxRounds) {
                viewModel.saveSimDefaultMaxRounds()
            }

            HStack {
                Text("Minutes Per Round")
                Spacer()
                Text("\(viewModel.simMinutesPerRound, format: .number.precision(.fractionLength(0)))")
                    .foregroundStyle(.secondary)
            }
            Slider(value: $viewModel.simMinutesPerRound, in: 15...180, step: 5)
                .onChange(of: viewModel.simMinutesPerRound) {
                    viewModel.saveSimMinutesPerRound()
                }

            Stepper(value: $viewModel.simAgentsPerHourMin, in: 1...50) {
                HStack {
                    Text("Agents Per Hour Min")
                    Spacer()
                    Text("\(viewModel.simAgentsPerHourMin)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.simAgentsPerHourMin) {
                viewModel.saveSimAgentsPerHourMin()
            }

            Stepper(value: $viewModel.simAgentsPerHourMax, in: 1...100) {
                HStack {
                    Text("Agents Per Hour Max")
                    Spacer()
                    Text("\(viewModel.simAgentsPerHourMax)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.simAgentsPerHourMax) {
                viewModel.saveSimAgentsPerHourMax()
            }

            Stepper(value: $viewModel.simSemaphoreLimit, in: 1...256) {
                HStack {
                    Text("Semaphore Limit")
                    Spacer()
                    Text("\(viewModel.simSemaphoreLimit)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.simSemaphoreLimit) {
                viewModel.saveSimSemaphoreLimit()
            }

            Divider()

            // Entity Classification
            Text("Entity Classification")
                .font(.headline)

            Picker("Classification Provider", selection: $viewModel.classificationProvider) {
                ForEach(ClassificationProviderOption.allCases) { option in
                    Text(option.displayName).tag(option)
                }
            }
            .onChange(of: viewModel.classificationProvider) {
                viewModel.saveClassificationProvider()
            }

            if viewModel.classificationProvider == .openrouter {
                TextField("Classification Model", text: $viewModel.simClassificationModel)
                    .onChange(of: viewModel.simClassificationModel) {
                        viewModel.saveSimClassificationModel()
                    }
            }

            if viewModel.classificationProvider == .onDevice {
                LabeledContent("Model Status", value: viewModel.onDeviceAvailabilityStatus)
                    .foregroundStyle(.secondary)
            }

            Stepper(value: $viewModel.simClassificationBatchSize, in: 5...100) {
                HStack {
                    Text("Batch Size")
                    Spacer()
                    Text("\(viewModel.simClassificationBatchSize)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.simClassificationBatchSize) {
                viewModel.saveSimClassificationBatchSize()
            }

            Stepper(value: $viewModel.simClassificationThreads, in: 1...32) {
                HStack {
                    Text("Concurrent Threads")
                    Spacer()
                    Text("\(viewModel.simClassificationThreads)")
                        .foregroundStyle(.secondary)
                }
            }
            .onChange(of: viewModel.simClassificationThreads) {
                viewModel.saveSimClassificationThreads()
            }

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Classification Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        viewModel.resetSimClassificationPromptToDefault()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                TextEditor(text: $viewModel.simClassificationPrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 150)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .onChange(of: viewModel.simClassificationPrompt) {
                        viewModel.saveSimClassificationPrompt()
                    }
            }

            Divider()

            // Agent Profile Prompt
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Profile Generation System Prompt")
                        .font(.headline)
                    Spacer()
                    Button("Reset to Default") {
                        viewModel.resetSimProfilePromptToDefault()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                }

                TextEditor(text: $viewModel.simProfilePrompt)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 200)
                    .scrollContentBackground(.hidden)
                    .padding(8)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(.rect(cornerRadius: 8))
                    .onChange(of: viewModel.simProfilePrompt) {
                        viewModel.saveSimProfilePrompt()
                    }
            }
        } header: {
            Text("Social Simulation")
        } footer: {
            Text("Configure OASIS social simulation. Click 'Check Environment' to auto-detect Python and verify camel-oasis is installed. Install with: pip install camel-oasis")
        }
    }
}

#Preview {
    SettingsView()
}
