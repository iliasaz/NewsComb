import Foundation
import Observation
import OSLog

/// View model for simulation report generation and display.
@MainActor
@Observable
final class SimulationReportViewModel {

    // MARK: - State

    let simulationId: String
    private(set) var isGenerating = false
    private(set) var statusMessage = ""
    private(set) var analysisText = ""
    private(set) var insightsText = ""
    private(set) var report: SimulationReport?
    var errorMessage: String?

    // MARK: - Internal

    private let reportService = SimulationReportService()
    private let logger = Logger(subsystem: "com.newscomb", category: "SimulationReportViewModel")

    init(simulationId: String) {
        self.simulationId = simulationId
    }

    var hasReport: Bool {
        report != nil
    }

    // MARK: - Actions

    func generateReport() async {
        isGenerating = true
        analysisText = ""
        insightsText = ""
        report = nil

        do {
            let result = try await reportService.generateReport(
                simulationId: simulationId,
                statusCallback: { [weak self] message in
                    self?.statusMessage = message
                },
                analysisTokenCallback: { [weak self] token in
                    self?.analysisText += token
                },
                insightTokenCallback: { [weak self] token in
                    self?.insightsText += token
                }
            )
            report = result
            statusMessage = "Report complete"
        } catch {
            logger.error("Report generation failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }

        isGenerating = false
    }
}
