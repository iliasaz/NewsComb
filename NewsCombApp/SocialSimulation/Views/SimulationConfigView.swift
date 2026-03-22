import SwiftUI
import GRDB

/// Configuration sheet for setting up and launching a simulation.
struct SimulationConfigView: View {
    let simulationId: String
    let onLaunch: (SimulationConfig, [Int64]) -> Void

    @Environment(\.dismiss) private var dismiss

    // Config state — initialized from persisted AppSettings
    @State private var maxRounds = AppSettings.defaultSimDefaultMaxRounds
    @State private var minutesPerRound = AppSettings.defaultSimMinutesPerRound
    @State private var maxAgents = 20
    @State private var useTwitter = true
    @State private var useReddit = false
    @State private var pythonPath = AppSettings.defaultSimPythonPath

    // Node selection
    @State private var availableNodes: [HypergraphNode] = []
    @State private var selectedNodeIds: Set<Int64> = []
    @State private var nodeSearchText = ""

    var body: some View {
        NavigationStack {
            Form {
                agentSection
                platformSection
                simulationParamsSection
                pythonSection
            }
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
            .onAppear { loadPersonaNodes() }
        }
    }

    // MARK: - Sections

    private var agentSection: some View {
        Section {
            Stepper("Max Agents: \(maxAgents)", value: $maxAgents, in: 3...100)

            if !availableNodes.isEmpty {
                DisclosureGroup("Select Entities (\(selectedNodeIds.count) selected)") {
                    ForEach(filteredNodes) { node in
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
                Text("No persona entities found")
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Agents")
        } footer: {
            Text("Leave selection empty to auto-select the most connected persona entities.")
        }
    }

    private var platformSection: some View {
        Section {
            Toggle("Twitter", isOn: $useTwitter)
            Toggle("Reddit", isOn: $useReddit)
        } header: {
            Text("Platforms")
        }
    }

    private var simulationParamsSection: some View {
        Section {
            Stepper("Rounds: \(maxRounds)", value: $maxRounds, in: 5...500)

            HStack {
                Text("Minutes per round")
                Spacer()
                Text(minutesPerRound, format: .number.precision(.fractionLength(0)))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $minutesPerRound, in: 15...180, step: 15)
        } header: {
            Text("Simulation Parameters")
        } footer: {
            let hours = Double(maxRounds) * minutesPerRound / 60.0
            Text("Total simulated time: \(hours, format: .number.precision(.fractionLength(1))) hours")
        }
    }

    private var pythonSection: some View {
        Section {
            TextField("Python Path", text: $pythonPath)
        } header: {
            Text("Python Configuration")
        } footer: {
            Text("Path to Python 3.11+ with camel-oasis installed.")
        }
    }

    // MARK: - Helpers

    private var canLaunch: Bool {
        (useTwitter || useReddit) && !availableNodes.isEmpty
    }

    private var filteredNodes: [HypergraphNode] {
        if nodeSearchText.isEmpty {
            return availableNodes
        }
        return availableNodes.filter {
            $0.label.localizedStandardContains(nodeSearchText)
        }
    }

    private func buildConfig() -> SimulationConfig {
        var platforms: [String] = []
        if useTwitter { platforms.append("twitter") }
        if useReddit { platforms.append("reddit") }

        // Load persisted agents-per-hour and semaphore from settings
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
            pythonPath: pythonPath,
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

                // Load persisted defaults
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
}
