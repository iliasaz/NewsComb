import SwiftUI

/// Lists all social simulations with options to create or delete.
struct SimulationListView: View {
    @State private var viewModel = SimulationListViewModel()
    @State private var showingNewSimulation = false
    @State private var newSimulationName = ""

    var body: some View {
        List {
            if viewModel.hasSimulations {
                ForEach(viewModel.simulations) { simulation in
                    NavigationLink(value: simulation) {
                        SimulationRow(simulation: simulation)
                    }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            viewModel.deleteSimulation(simulation)
                        }
                    }
                }
            }
        }
        .navigationTitle("Social Simulation")
        .navigationDestination(for: SocialSimulation.self) { simulation in
            SimulationDashboardView(simulation: simulation)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("New Simulation", systemImage: "plus") {
                    newSimulationName = "Simulation \(viewModel.simulations.count + 1)"
                    showingNewSimulation = true
                }
            }
        }
        .overlay {
            if !viewModel.hasSimulations {
                ContentUnavailableView {
                    Label("No Simulations", systemImage: "person.3.sequence.fill")
                } description: {
                    Text("Create a social simulation to see how news entities might interact on social media.")
                } actions: {
                    Button("New Simulation") {
                        newSimulationName = "Simulation 1"
                        showingNewSimulation = true
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
        }
        .sheet(isPresented: $showingNewSimulation) {
            NewSimulationSheet(
                name: $newSimulationName,
                onCreate: { name in
                    if let simulation = viewModel.createSimulation(name: name) {
                        showingNewSimulation = false
                        // Navigation handled by the list
                        _ = simulation
                    }
                }
            )
        }
        .onAppear {
            viewModel.loadSimulations()
        }
    }
}

// MARK: - Row

private struct SimulationRow: View {
    let simulation: SocialSimulation

    var body: some View {
        Label {
            VStack(alignment: .leading) {
                Text(simulation.name)
                    .font(.headline)
                HStack(spacing: 8) {
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                    if simulation.agentCount > 0 {
                        Text("\(simulation.agentCount) agents")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if simulation.roundCount > 0 {
                        Text("Round \(simulation.roundCount)/\(simulation.maxRounds)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } icon: {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
        }
    }

    private var statusText: String {
        switch simulation.status {
        case "configuring":
            simulation.agentCount > 0 ? "\(simulation.agentCount) agents ready" : "New"
        case "running": "Running"
        case "completed": "Completed"
        case "failed": "Failed"
        default: simulation.status.capitalized
        }
    }

    private var statusColor: Color {
        switch simulation.status {
        case "running": .green
        case "completed": .blue
        case "failed": .red
        case "configuring": .orange
        default: .secondary
        }
    }

    private var statusIcon: String {
        switch simulation.status {
        case "running": "play.circle.fill"
        case "completed": "checkmark.circle.fill"
        case "failed": "exclamationmark.circle.fill"
        case "configuring": "arrow.right.circle.fill"
        default: "circle"
        }
    }
}

// MARK: - New Simulation Sheet

private struct NewSimulationSheet: View {
    @Binding var name: String
    let onCreate: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Simulation Name", text: $name)
                } header: {
                    Text("Name")
                }
            }
            .navigationTitle("New Simulation")
            #if os(macOS)
            .frame(minWidth: 350, minHeight: 200)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { onCreate(name) }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
