import Foundation
import GRDB
import Observation
import OSLog

/// View model for the Answer Detail view, managing deep analysis state and persistence.
@MainActor
@Observable
final class AnswerDetailViewModel {
    /// The GraphRAG response being displayed.
    let response: GraphRAGResponse

    /// The persisted history item (used for saving deep analysis).
    private(set) var historyItem: QueryHistoryItem

    /// The deep analysis result, if available.
    private(set) var deepAnalysisResult: DeepAnalysisResult?

    /// Whether a deep analysis is currently in progress.
    private(set) var isAnalyzing = false

    /// Error message from the last analysis attempt.
    private(set) var analysisError: String?

    private let deepAnalysisService = DeepAnalysisService()
    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "AnswerDetailViewModel")

    /// Creates a view model with the given history item.
    ///
    /// - Parameter historyItem: The persisted query history item.
    init(historyItem: QueryHistoryItem) {
        self.historyItem = historyItem
        self.response = historyItem.toGraphRAGResponse()
        self.deepAnalysisResult = historyItem.toDeepAnalysisResult()
    }

    /// Whether deep analysis is available (LLM provider configured).
    var isDeepAnalysisAvailable: Bool {
        let service = HypergraphService()
        return service.isConfigured()
    }

    /// Whether the history item already has deep analysis results.
    var hasExistingAnalysis: Bool {
        deepAnalysisResult != nil
    }

    /// The button label - "Dive Deeper" for first analysis, "Analyze Again" for re-analysis.
    var analyzeButtonLabel: String {
        hasExistingAnalysis ? "Analyze Again" : "Dive Deeper"
    }

    /// Performs deep analysis using the multi-agent workflow.
    func performDeepAnalysis() async {
        guard !isAnalyzing else { return }

        isAnalyzing = true
        analysisError = nil

        logger.info("Starting deep analysis for query: \(self.response.query, privacy: .public)")

        do {
            let result = try await deepAnalysisService.analyze(
                question: response.query,
                initialAnswer: response.answer,
                relatedNodes: response.relatedNodes,
                reasoningPaths: response.reasoningPaths,
                graphPaths: response.graphPaths
            )

            deepAnalysisResult = result
            logger.info("Deep analysis completed successfully")

            // Persist the result
            try saveDeepAnalysis(result)

        } catch {
            logger.error("Deep analysis failed: \(error.localizedDescription, privacy: .public)")
            analysisError = error.localizedDescription
        }

        isAnalyzing = false
    }

    /// Saves the deep analysis result to the database.
    private func saveDeepAnalysis(_ result: DeepAnalysisResult) throws {
        guard let itemId = historyItem.id else {
            logger.warning("Cannot save deep analysis: history item has no ID")
            return
        }

        let updatedItem = historyItem.withDeepAnalysis(result)

        try database.write { db in
            try db.execute(
                sql: """
                    UPDATE query_history
                    SET synthesized_analysis = ?,
                        hypotheses = ?,
                        analyzed_at = ?
                    WHERE id = ?
                """,
                arguments: [
                    result.synthesizedAnswer,
                    result.hypotheses,
                    result.analyzedAt,
                    itemId
                ]
            )
        }

        historyItem = updatedItem
        logger.info("Deep analysis saved to database for history item \(itemId)")
    }
}
