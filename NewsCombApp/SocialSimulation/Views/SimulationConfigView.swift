import SwiftUI
import GRDB

/// Configuration sheet for setting up and launching a simulation.
struct SimulationConfigView: View {
    let simulationId: String
    let onLaunch: (SimulationConfig, [Int64]) -> Void

    @Environment(\.dismiss) private var dismiss

    // Config state
    @State private var maxRounds = AppSettings.defaultSimDefaultMaxRounds
    @State private var minutesPerRound = AppSettings.defaultSimMinutesPerRound
    @State private var maxAgents = 20
    @State private var useTwitter = true
    @State private var useReddit = false
    @State private var pythonPath = AppSettings.defaultSimPythonPath

    // Environment
    @State private var detectedPythonPath: String?
    @State private var oasisStatus: OasisStatus?
    @State private var isCheckingEnvironment = true

    // Node selection
    @State private var availableNodes: [HypergraphNode] = []
    @State private var selectedNodeIds: Set<Int64> = []

    var body: some View {
        NavigationStack {
            Form {
                environmentSection
                agentSection
                platformSection
                simulationParamsSection
            }
            .formStyle(.grouped)
            .navigationTitle("Configure Simulation")
            #if os(macOS)
            .frame(minWidth: 500, minHeight: 500)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Launch Simulation") {
                        let config = buildConfig()
                        onLaunch(config, Array(selectedNodeIds))
                        dismiss()
                    }
                    .disabled(!canLaunch)
                }
            }
            .onAppear {
                loadPersonaNodes()
                checkEnvironment()
            }
        }
    }

    // MARK: - Environment

    private var environmentSection: some View {
        Section {
            LabeledContent("Python") {
                if isCheckingEnvironment {
                    ProgressView()
                        .controlSize(.small)
                } else if let path = detectedPythonPath {
                    Text(path)
                        .foregroundStyle(.green)
                        .font(.caption)
                } else {
                    Text("Not found")
                        .foregroundStyle(.red)
                }
            }

            LabeledContent("OASIS") {
                if isCheckingEnvironment {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    switch oasisStatus {
                    case .installed(let version):
                        Text("v\(version)")
                            .foregroundStyle(.green)
                    case .notInstalled:
                        Text("Not installed")
                            .foregroundStyle(.red)
                    case .pythonNotFound, .error, nil:
                        Text("Unavailable")
                            .foregroundStyle(.red)
                    }
                }
            }
        } header: {
            Text("Environment")
        } footer: {
            if !(oasisStatus?.isInstalled ?? false) && !isCheckingEnvironment {
                Text("Install with: pip install camel-oasis")
            }
        }
    }

    // MARK: - Agents

    private var agentSection: some View {
        Section {
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
                                if isOn {
                                    selectedNodeIds.insert(node.id!)
                                } else {
                                    selectedNodeIds.remove(node.id!)
                                }
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
            } else {
                Text("No persona entities found in the knowledge graph.")
                    .foregroundStyle(.secondary)
                    .font(.callout)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Leave selection empty to auto-select the most connected persona entities.")
        }
    }

    // MARK: - Platforms

    private var platformSection: some View {
        Section {
            Toggle("Twitter", isOn: $useTwitter)
            Toggle("Reddit", isOn: $useReddit)
        } header: {
            Text("Platforms")
        }
    }

    // MARK: - Simulation Parameters

    private var simulationParamsSection: some View {
        Section {
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
        } header: {
            Text("Simulation Parameters")
        } footer: {
            let hours = Double(maxRounds) * minutesPerRound / 60.0
            Text("Total simulated time: \(hours, format: .number.precision(.fractionLength(1))) hours")
        }
    }

    // MARK: - Helpers

    private var canLaunch: Bool {
        (useTwitter || useReddit) && !isCheckingEnvironment
    }

    private func buildConfig() -> SimulationConfig {
        var platforms: [String] = []
        if useTwitter { platforms.append("twitter") }
        if useReddit { platforms.append("reddit") }

        var agentsMin = AppSettings.defaultSimAgentsPerHourMin
        var agentsMax = AppSettings.defaultSimAgentsPerHourMax
        var semaphore = AppSettings.defaultSimSemaphoreLimit
        if let db = try? Database.shared.read({ db in db }) {
            if let s = try? AppSettings.filter(AppSettings.Columns.key == AppSettings.simAgentsPerHourMin).fetchOne(db),
               let v = Int(s.value) { agentsMin = v }
            if let s = try? AppSettings.filter(AppSettings.Columns.key == AppSettings.simAgentsPerHourMax).fetchOne(db),
               let v = Int(s.value) { agentsMax = v }
            if let s = try? AppSettings.filter(AppSettings.Columns.key == AppSettings.simSemaphoreLimit).fetchOne(db),
               let v = Int(s.value) { semaphore = v }
        }

        return SimulationConfig(
            maxRounds: maxRounds,
            minutesPerRound: minutesPerRound,
            platforms: platforms,
            agentsPerHourMin: agentsMin,
            agentsPerHourMax: agentsMax,
            pythonPath: detectedPythonPath ?? pythonPath,
            semaphoreLimit: semaphore
        )
    }

    private func loadPersonaNodes() {
        let personaTypes = AgentProfileService.personaNodeTypes
        do {
            let types = personaTypes.map { "'\($0)'" }.joined(separator: ", ")
            try Database.shared.read { db in
                availableNodes = try HypergraphNode.fetchAll(db, sql: """
                    SELECT n.*
                    FROM hypergraph_node n
                    JOIN hypergraph_incidence i ON i.node_id = n.id
                    WHERE LOWER(n.node_type) IN (\(types))
                    GROUP BY n.id
                    HAVING COUNT(DISTINCT i.edge_id) >= 2
                    ORDER BY COUNT(DISTINCT i.edge_id) DESC
                    LIMIT 200
                    """)

                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simPythonPath).fetchOne(db) {
                    pythonPath = s.value
                }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simDefaultMaxRounds).fetchOne(db),
                   let v = Int(s.value) {
                    maxRounds = v
                }
                if let s = try AppSettings.filter(AppSettings.Columns.key == AppSettings.simMinutesPerRound).fetchOne(db),
                   let v = Double(s.value) {
                    minutesPerRound = v
                }
            }
        } catch {
            availableNodes = []
        }
    }

    private func checkEnvironment() {
        Task {
            let envService = OasisEnvironmentService()
            detectedPythonPath = await envService.detectPythonPath()
            if let python = detectedPythonPath {
                oasisStatus = await envService.checkOasisInstalled(pythonPath: python)
            } else {
                oasisStatus = .pythonNotFound
            }
            isCheckingEnvironment = false
        }
    }
}
