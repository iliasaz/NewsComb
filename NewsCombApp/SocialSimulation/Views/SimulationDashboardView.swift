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
            statusSection

            if viewModel.hasAgents {
                statsSection
                contentSection
                toolsSection
            }
        }
        .navigationTitle(viewModel.simulation.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isRunning {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        Task { await viewModel.stopSimulation() }
                    }
                } else if !viewModel.hasAgents {
                    Button("Configure", systemImage: "gearshape") {
                        showingConfig = true
                    }
                } else if viewModel.simulation.status == "configuring" {
                    Button("Launch", systemImage: "play.fill") {
                        showingConfig = true
                    }
                }
            }

            if !viewModel.hasAgents {
                ToolbarItem(placement: .primaryAction) {
                    Button("Generate Profiles", systemImage: "person.crop.rectangle.stack") {
                        Task { await viewModel.generateProfiles() }
                    }
                    .disabled(viewModel.isGeneratingProfiles)
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
        .onAppear { viewModel.loadData() }
    }

    // MARK: - Sections

    @ViewBuilder
    private var statusSection: some View {
        if viewModel.isGeneratingProfiles || viewModel.isRunning {
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
        } else if case .failed(let message) = viewModel.status {
            Section {
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            } header: {
                Text("Status")
            }
        }
    }

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
}
