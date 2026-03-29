import SwiftUI

/// Main view for a simulation — environment, classification, progress,
/// results, and activity log. Configuration is handled by SimulationConfigView.
struct SimulationDashboardView: View {
    @State private var viewModel: SimulationDashboardViewModel
    @State private var selectedTab = "feed"
    @State private var showingConfig = false

    init(simulation: SocialSimulation) {
        _viewModel = State(initialValue: SimulationDashboardViewModel(simulation: simulation))
    }

    var body: some View {
        List {
            // Show setup sections when no agents yet
            if !viewModel.hasAgents && !viewModel.isRunning && !viewModel.isGeneratingProfiles {
                environmentSection
                classificationSection
                configureSection
            }

            // Show launch controls when agents exist but simulation hasn't run
            if viewModel.hasAgents && !viewModel.isRunning && !viewModel.hasPosts {
                configureSection
            }

            if viewModel.isGeneratingProfiles || viewModel.status.isProcessing || viewModel.isClassifying {
                progressSection
            } else if viewModel.status.isDone {
                completedSection
            } else if case .failed = viewModel.status {
                errorSection
            }

            if viewModel.hasAgents {
                statsSection
                contentSection
                toolsSection
            }

            activityLogSection
        }
        .navigationTitle(viewModel.simulation.name)
        .toolbar {
            if viewModel.status.isProcessing {
                ToolbarItem(placement: .primaryAction) {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        Task { await viewModel.stopSimulation() }
                    }
                }
            }
        }
        .sheet(isPresented: $showingConfig) {
            SimulationConfigView(
                simulationId: viewModel.simulation.id
            ) { config, nodeIds, maxAgents in
                Task {
                    if !viewModel.hasAgents {
                        await viewModel.generateProfiles(
                            nodeIds: nodeIds,
                            maxAgents: maxAgents
                        )
                    }
                    await viewModel.startSimulation(config: config)
                }
            }
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
        .onAppear {
            viewModel.loadData()
            Task { await viewModel.checkEnvironment() }
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section {
            EnvironmentStatusRow(
                label: "Python",
                isChecking: viewModel.isCheckingEnvironment,
                value: viewModel.pythonPath,
                placeholder: "Checking\u{2026}"
            )

            EnvironmentStatusRow(
                label: "OASIS",
                isChecking: viewModel.isCheckingEnvironment,
                value: viewModel.oasisStatus.map { status in
                    switch status {
                    case .installed(let v): "v\(v)"
                    case .notInstalled: "Not installed"
                    case .pythonNotFound: "Python not found"
                    case .error(let msg): msg
                    }
                },
                placeholder: "Checking\u{2026}",
                isError: !(viewModel.oasisStatus?.isInstalled ?? true)
            )
        } header: {
            Text("Environment")
        }
    }

    // MARK: - Classification

    private var classificationSection: some View {
        Section {
            Button("Classify Entities", systemImage: "tag") {
                Task { await viewModel.classifyEntities() }
            }
            .disabled(viewModel.isClassifying)

            if viewModel.isClassifying {
                ProgressView(value: viewModel.classificationProgress)
            }
        } header: {
            Text("Entity Classification")
        } footer: {
            Text("Classify knowledge graph entities as persons, organizations, etc. to identify simulation personas.")
        }
    }

    // MARK: - Configure & Launch

    private var configureSection: some View {
        Section {
            Button("Configure & Launch", systemImage: "play.fill") {
                showingConfig = true
            }
            .buttonStyle(.borderedProminent)
        } header: {
            if viewModel.hasAgents {
                Text("Launch")
            } else {
                Text("Configuration")
            }
        } footer: {
            if viewModel.hasAgents {
                Text("\(viewModel.agents.count) agents ready. Configure rounds and platforms, then launch.")
            }
        }
    }

    // MARK: - Completed

    private var completedSection: some View {
        Section {
            Label {
                VStack(alignment: .leading, spacing: 4) {
                    Text(viewModel.statusMessage)
                        .font(.headline)
                    if let stats = viewModel.stats, stats.postCount > 0 {
                        Text("\(stats.postCount) posts, \(stats.interactionCount) interactions")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } icon: {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: - Progress

    @ViewBuilder
    private var progressSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    ProgressView()
                        .controlSize(.small)
                    Text(viewModel.statusMessage)
                        .font(.headline)
                }

                if viewModel.isGeneratingProfiles {
                    ProgressView(value: viewModel.profileProgress)
                }

                if viewModel.isClassifying {
                    ProgressView(value: viewModel.classificationProgress)
                }

                if case .running(let round, let total) = viewModel.status {
                    ProgressView(value: Double(round), total: Double(total))
                    Text("Round \(round) of \(total)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Status")
        }
    }

    // MARK: - Error

    @ViewBuilder
    private var errorSection: some View {
        if case .failed(let message) = viewModel.status {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } header: {
                Text("Status")
            }
        }
    }

    // MARK: - Stats

    @ViewBuilder
    private var statsSection: some View {
        if let stats = viewModel.stats {
            Section {
                LabeledContent("Agents", value: "\(stats.agentCount)")
                LabeledContent("Posts", value: "\(stats.postCount)")
                LabeledContent("Interactions", value: "\(stats.interactionCount)")
                LabeledContent("Connections", value: "\(stats.connectionCount)")
                if stats.latestRound > 0 {
                    LabeledContent("Latest Round", value: "\(stats.latestRound)")
                }
            } header: {
                Text("Statistics")
            }

            if !viewModel.actionBreakdown.isEmpty {
                Section {
                    ForEach(viewModel.actionBreakdown.sorted(by: { $0.value > $1.value }), id: \.key) { action, count in
                        LabeledContent(action.replacing("_", with: " ").capitalized, value: "\(count)")
                    }
                } header: {
                    Text("Actions Breakdown")
                }
            }
        }
    }

    // MARK: - Content

    private var contentSection: some View {
        Section {
            Picker("View", selection: $selectedTab) {
                Text("Feed").tag("feed")
                Text("Agents").tag("agents")
                Text("Groups").tag("groups")
            }
            .pickerStyle(.segmented)

            switch selectedTab {
            case "feed":
                SimulationFeedView(
                    posts: viewModel.recentPosts,
                    agents: viewModel.agents
                )
            case "agents":
                SimulationAgentListView(
                    agents: viewModel.agents,
                    simulationId: viewModel.simulation.id
                )
            case "groups":
                SimulationGroupsView(simulationId: viewModel.simulation.id)
            default:
                EmptyView()
            }
        } header: {
            Text("Content")
        }
    }

    // MARK: - Tools

    @ViewBuilder
    private var toolsSection: some View {
        if viewModel.hasAgents {
            Section {
                NavigationLink {
                    SimulationNetworkView(simulationId: viewModel.simulation.id)
                } label: {
                    Label("Social Network", systemImage: "network")
                }
                NavigationLink {
                    SimulationReportView(simulationId: viewModel.simulation.id)
                } label: {
                    Label("Generate Report", systemImage: "doc.text.magnifyingglass")
                }

                Button("Re-ingest Data", systemImage: "arrow.trianglehead.2.clockwise") {
                    viewModel.reingestData()
                }
            } header: {
                Text("Tools")
            }
        }
    }

    // MARK: - Activity Log

    private var activityLogSection: some View {
        Section {
            if viewModel.activityLog.isEmpty {
                Text("No activity yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.activityLog.prefix(30)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Text(entry.timestamp, format: .dateTime.hour().minute().second())
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        Text(entry.message)
                            .font(.caption)
                            .foregroundStyle(entry.isError ? .red : .primary)
                    }
                }
            }
        } header: {
            Text("Activity Log")
        }
    }
}

// MARK: - Environment Status Row

private struct EnvironmentStatusRow: View {
    let label: String
    let isChecking: Bool
    let value: String?
    var placeholder: String = ""
    var isError: Bool = false

    var body: some View {
        LabeledContent(label) {
            if isChecking {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.small)
                    Text(placeholder)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else if let value {
                Text(value)
                    .font(.caption)
                    .foregroundStyle(isError ? .red : .green)
            } else {
                Text("Unknown")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
