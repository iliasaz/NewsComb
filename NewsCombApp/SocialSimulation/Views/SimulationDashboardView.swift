import SwiftUI
import GRDB

/// Main view for a simulation — environment, classification, config, launch,
/// progress, results, and activity log all inline in a single scrollable list.
struct SimulationDashboardView: View {
    @State private var viewModel: SimulationDashboardViewModel
    @State private var selectedTab = "feed"

    // Inline config state
    @State private var maxRounds = AppSettings.defaultSimDefaultMaxRounds
    @State private var minutesPerRound = AppSettings.defaultSimMinutesPerRound
    @State private var maxAgents = 20
    @State private var useTwitter = true
    @State private var useReddit = false
    @State private var availableNodes: [HypergraphNode] = []
    @State private var selectedNodeIds: Set<Int64> = []

    init(simulation: SocialSimulation) {
        _viewModel = State(initialValue: SimulationDashboardViewModel(simulation: simulation))
    }

    var body: some View {
        List {
            // Show config + environment when not yet running
            if !viewModel.hasAgents && !viewModel.isRunning && !viewModel.isGeneratingProfiles {
                environmentSection
                classificationSection
                configSection
            }

            if viewModel.isGeneratingProfiles || viewModel.isRunning || viewModel.isClassifying {
                progressSection
            }

            if case .failed = viewModel.status {
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
            if viewModel.isRunning {
                ToolbarItem(placement: .primaryAction) {
                    Button("Stop", systemImage: "stop.fill", role: .destructive) {
                        Task { await viewModel.stopSimulation() }
                    }
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
            loadConfigDefaults()
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

    // MARK: - Inline Config

    private var configSection: some View {
        Section {
            // Agents
            Stepper(value: $maxAgents, in: 3...100) {
                LabeledContent("Max Agents") {
                    Text("\(maxAgents)")
                        .foregroundStyle(.secondary)
                }
            }

            if !availableNodes.isEmpty {
                DisclosureGroup("Select Entities (\(selectedNodeIds.count) selected)") {
                    ForEach(availableNodes) { node in
                        Toggle(isOn: Binding(
                            get: { selectedNodeIds.contains(node.id!) },
                            set: { isOn in
                                if isOn { selectedNodeIds.insert(node.id!) }
                                else { selectedNodeIds.remove(node.id!) }
                            }
                        )) {
                            VStack(alignment: .leading) {
                                Text(node.label)
                                if let type = node.nodeType {
                                    Text(type)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }

            // Platforms
            Toggle("Twitter", isOn: $useTwitter)
            Toggle("Reddit", isOn: $useReddit)

            // Parameters
            Stepper(value: $maxRounds, in: 5...500) {
                LabeledContent("Rounds") {
                    Text("\(maxRounds)")
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading) {
                LabeledContent("Minutes per round") {
                    Text(minutesPerRound, format: .number.precision(.fractionLength(0)))
                        .foregroundStyle(.secondary)
                }
                Slider(value: $minutesPerRound, in: 15...180, step: 15)
            }

            // Launch
            Button("Launch Simulation", systemImage: "play.fill") {
                Task { await launchSimulation() }
            }
            .disabled(!canLaunch)
            .buttonStyle(.borderedProminent)
        } header: {
            Text("Configuration")
        } footer: {
            let hours = Double(maxRounds) * minutesPerRound / 60.0
            Text("Total simulated time: \(hours, format: .number.precision(.fractionLength(1))) hours. Leave entity selection empty to auto-select.")
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

    // MARK: - Actions

    private var canLaunch: Bool {
        (useTwitter || useReddit) && !viewModel.isCheckingEnvironment
    }

    private func launchSimulation() async {
        let defaults = SimulationConfig.loadPersistedDefaults()

        var platforms: [String] = []
        if useTwitter { platforms.append("twitter") }
        if useReddit { platforms.append("reddit") }

        let config = SimulationConfig(
            maxRounds: maxRounds,
            minutesPerRound: minutesPerRound,
            platforms: platforms,
            agentsPerHourMin: defaults.agentsPerHourMin,
            agentsPerHourMax: defaults.agentsPerHourMax,
            pythonPath: viewModel.pythonPath ?? AppSettings.defaultSimPythonPath,
            semaphoreLimit: defaults.semaphoreLimit
        )

        if !viewModel.hasAgents {
            await viewModel.generateProfiles(
                nodeIds: Array(selectedNodeIds),
                maxAgents: maxAgents
            )
        }
        await viewModel.startSimulation(config: config)
    }

    private func loadConfigDefaults() {
        // Load persisted config defaults and available nodes
        do {
            try Database.shared.read { db in
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simDefaultMaxRounds).fetchOne(db),
                   let v = Int(s.value) { maxRounds = v }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simMinutesPerRound).fetchOne(db),
                   let v = Double(s.value) { minutesPerRound = v }

                // Load available nodes (typed personas first, then fallback)
                let personaTypes = AgentProfileService.personaNodeTypes
                let types = personaTypes.map { "'\($0)'" }.joined(separator: ", ")

                var nodes = try HypergraphNode.fetchAll(db, sql: """
                    SELECT n.*
                    FROM hypergraph_node n
                    JOIN hypergraph_incidence i ON i.node_id = n.id
                    WHERE LOWER(n.node_type) IN (\(types))
                    GROUP BY n.id
                    HAVING COUNT(DISTINCT i.edge_id) >= 2
                    ORDER BY COUNT(DISTINCT i.edge_id) DESC
                    LIMIT 200
                    """)

                if nodes.isEmpty {
                    nodes = try HypergraphNode.fetchAll(db, sql: """
                        SELECT n.*
                        FROM hypergraph_node n
                        JOIN hypergraph_incidence i ON i.node_id = n.id
                        WHERE LENGTH(n.label) <= 80
                        GROUP BY n.id
                        HAVING COUNT(DISTINCT i.edge_id) >= 1
                        ORDER BY COUNT(DISTINCT i.edge_id) DESC
                        LIMIT 200
                        """)
                }
                availableNodes = nodes
            }
        } catch {
            // Use defaults
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
