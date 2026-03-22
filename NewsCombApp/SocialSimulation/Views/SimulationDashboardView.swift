import SwiftUI

/// Main view for a simulation — shows progress, stats, and content tabs.
struct SimulationDashboardView: View {
    @State private var viewModel: SimulationDashboardViewModel
    @State private var showingConfig = false
    @State private var selectedTab = "feed"

    init(simulation: SocialSimulation) {
        _viewModel = State(initialValue: SimulationDashboardViewModel(simulation: simulation))
    }

    var body: some View {
        List {
            if !viewModel.hasAgents && !viewModel.isRunning && !viewModel.isGeneratingProfiles {
                onboardingSection
            }

            if viewModel.isGeneratingProfiles || viewModel.isRunning {
                progressSection
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
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        Task { await viewModel.stopSimulation() }
                    }
                } else if viewModel.hasAgents && viewModel.simulation.status == "configuring" {
                    Button("Launch", systemImage: "play.fill") {
                        showingConfig = true
                    }
                }
            }
        }
        .sheet(isPresented: $showingConfig) {
            SimulationConfigView(
                simulationId: viewModel.simulation.id
            ) { config, nodeIds in
                Task {
                    if !viewModel.hasAgents {
                        await viewModel.generateProfiles(nodeIds: nodeIds, maxAgents: 30)
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

    // MARK: - Onboarding

    private var onboardingSection: some View {
        Section {
            // Environment status
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

            if viewModel.environmentChecked {
                if viewModel.environmentReady {
                    Button("Configure & Launch Simulation", systemImage: "play.fill") {
                        showingConfig = true
                    }
                    .buttonStyle(.borderedProminent)
                } else {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Environment not ready")
                            .font(.subheadline)
                            .bold()
                        Text("Install Python 3.10+ and camel-oasis:\npip install camel-oasis")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("Setup")
        } footer: {
            if !viewModel.environmentChecked {
                Text("Checking environment\u{2026}")
            }
        }
    }

    // MARK: - Progress

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
        }
    }

    // MARK: - Content

    private var contentSection: some View {
        Section {
            Picker("View", selection: $selectedTab) {
                Text("Feed").tag("feed")
                Text("Agents").tag("agents")
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
