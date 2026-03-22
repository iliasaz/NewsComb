import SwiftUI

/// Displays the generated simulation report with analysis and insights.
struct SimulationReportView: View {
    @State private var viewModel: SimulationReportViewModel

    init(simulationId: String) {
        _viewModel = State(initialValue: SimulationReportViewModel(simulationId: simulationId))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                if viewModel.isGenerating {
                    progressSection
                }

                if !viewModel.analysisText.isEmpty {
                    reportSection(title: "Analysis", content: viewModel.analysisText)
                }

                if !viewModel.insightsText.isEmpty {
                    reportSection(title: "Insights", content: viewModel.insightsText)
                }

                if !viewModel.hasReport && !viewModel.isGenerating {
                    emptyState
                }
            }
            .padding()
        }
        .navigationTitle("Simulation Report")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if viewModel.isGenerating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button("Generate Report", systemImage: "doc.text.magnifyingglass") {
                        Task { await viewModel.generateReport() }
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
    }

    // MARK: - Sections

    private var progressSection: some View {
        HStack {
            ProgressView()
                .controlSize(.small)
            Text(viewModel.statusMessage)
                .foregroundStyle(.secondary)
        }
    }

    private func reportSection(title: String, content: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.title2)
                .bold()

            Text(LocalizedStringKey(content))
                .textSelection(.enabled)
        }
        .padding()
        .background(.quaternary.opacity(0.5))
        .clipShape(.rect(cornerRadius: 12))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Report", systemImage: "doc.text.magnifyingglass")
        } description: {
            Text("Generate a report to analyze the simulation results.")
        } actions: {
            Button("Generate Report") {
                Task { await viewModel.generateReport() }
            }
            .buttonStyle(.borderedProminent)
        }
    }
}
