import Foundation
import GRDB
import Observation
import OSLog

/// View model for the Answer Detail view, supporting both static history display
/// and live progressive query rendering via `AsyncStream`.
@MainActor
@Observable
final class AnswerDetailViewModel {

    // MARK: - Display State

    /// The user's question.
    private(set) var question: String

    /// The generated answer text (streams in token-by-token during live queries).
    private(set) var answerText: String = ""

    /// Related knowledge graph nodes.
    private(set) var relatedNodes: [GraphRAGResponse.RelatedNode] = []

    /// Multi-hop reasoning paths between concepts.
    private(set) var reasoningPaths: [GraphRAGResponse.ReasoningPath] = []

    /// Supporting graph relationships.
    private(set) var graphPaths: [GraphRAGResponse.GraphPath] = []

    /// Source articles that informed the answer.
    private(set) var sourceArticles: [GraphRAGResponse.SourceArticle] = []

    /// When the answer was generated.
    private(set) var generatedAt: Date?

    // MARK: - Pipeline State

    /// Whether this view model is running a live query pipeline.
    private(set) var isLiveQuery: Bool = false

    /// Human-readable status of the current pipeline phase.
    private(set) var pipelineStatus: String = ""

    /// Whether the pipeline has completed (or the view was initialized from history).
    private(set) var isCompleted: Bool = false

    /// Error message if the pipeline failed.
    private(set) var pipelineError: String?

    // MARK: - Deep Analysis State

    /// The deep analysis result, if available.
    private(set) var deepAnalysisResult: DeepAnalysisResult?

    /// Whether a deep analysis is currently in progress.
    private(set) var isAnalyzing = false

    /// Error message from the last analysis attempt.
    private(set) var analysisError: String?

    /// Human-readable status of the current deep analysis agent.
    private(set) var analysisStatus: String = ""

    /// Streaming text from the Engineer agent (synthesis).
    private(set) var streamingSynthesis: String = ""

    /// Streaming text from the Hypothesizer agent (hypotheses).
    private(set) var streamingHypotheses: String = ""

    // MARK: - Internal

    /// The persisted history item (set after history init or after pipeline completion).
    private(set) var historyItem: QueryHistoryItem?

    /// Parameters for a live query (nil when initialized from history).
    private let liveQueryParams: LiveQueryNavigation?

    private let graphRAGService = GraphRAGService()
    private let deepAnalysisService = DeepAnalysisService()
    private let queryHistoryService = QueryHistoryService()
    private let userRoleService = UserRoleService()
    private let database = Database.shared
    private let logger = Logger(subsystem: "com.newscomb", category: "AnswerDetailViewModel")

    // MARK: - History Mode Initializer

    /// Creates a view model from a persisted query history item (static display).
    init(historyItem: QueryHistoryItem) {
        self.historyItem = historyItem
        self.liveQueryParams = nil

        let response = historyItem.toGraphRAGResponse()
        self.question = response.query
        self.answerText = response.answer
        self.relatedNodes = response.relatedNodes
        self.reasoningPaths = response.reasoningPaths
        self.graphPaths = response.graphPaths
        self.sourceArticles = response.sourceArticles
        self.generatedAt = response.generatedAt
        self.isCompleted = true
        self.deepAnalysisResult = historyItem.toDeepAnalysisResult()
    }

    // MARK: - Live Query Mode Initializer

    /// Creates a view model for a live query that will progressively populate via the pipeline.
    init(liveQuery: LiveQueryNavigation) {
        self.historyItem = nil
        self.liveQueryParams = liveQuery
        self.question = liveQuery.query
        self.isLiveQuery = true
    }

    // MARK: - Pipeline

    /// Starts the query pipeline and consumes the `AsyncStream`, updating
    /// observable properties as each phase completes.
    ///
    /// Called from the view's `.task` modifier. In history mode this is a no-op.
    /// The `.task` modifier automatically cancels the task when the view disappears,
    /// which propagates through to the stream's `onTermination` handler.
    func startPipeline() async {
        guard let params = liveQueryParams, isLiveQuery, !isCompleted else { return }

        let stream = graphRAGService.queryStream(
            params.query,
            rolePrompt: params.rolePrompt
        )

        for await update in stream {
            switch update {
            case .status(let status):
                pipelineStatus = status

            case .keywords:
                // Keywords are logged but not displayed
                break

            case .relatedNodes(let nodes):
                relatedNodes = nodes

            case .reasoningPaths(let paths):
                reasoningPaths = paths

            case .graphPaths(let paths):
                graphPaths = paths

            case .answerToken(let token):
                answerText += token

            case .sourceArticles(let articles):
                sourceArticles = articles

            case .completed(let response):
                // Ensure all display properties reflect the final response.
                // For streaming providers answerText was built token-by-token;
                // for non-streaming providers the single .answerToken already set it.
                // This assignment acts as a safety net for both cases.
                answerText = response.answer
                relatedNodes = response.relatedNodes
                reasoningPaths = response.reasoningPaths
                graphPaths = response.graphPaths
                sourceArticles = response.sourceArticles
                generatedAt = response.generatedAt
                isLiveQuery = false
                isCompleted = true
                pipelineStatus = ""
                persistToHistory(response)

            case .failed(let error):
                pipelineError = error.localizedDescription
                isLiveQuery = false
                pipelineStatus = ""
            }
        }
    }

    // MARK: - History Persistence

    /// Persists the completed response to query history.
    private func persistToHistory(_ response: GraphRAGResponse) {
        do {
            try queryHistoryService.save(response)
            // Fetch the saved item to get the database ID
            let recent = try queryHistoryService.fetchRecent(limit: 1)
            if let saved = recent.first, saved.query == response.query {
                historyItem = saved
            }
            logger.info("Pipeline result saved to history")
        } catch {
            logger.error("Failed to save pipeline result: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Deep Analysis

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
        analysisStatus = ""
        streamingSynthesis = ""
        streamingHypotheses = ""

        logger.info("Starting deep analysis for query: \(self.question, privacy: .public)")

        // Load the active user role
        let activeRole = try? userRoleService.fetchActive()
        if let role = activeRole {
            logger.info("Using active role for deep analysis: \(role.name, privacy: .public)")
        }

        do {
            let result = try await deepAnalysisService.analyze(
                question: question,
                initialAnswer: answerText,
                relatedNodes: relatedNodes,
                reasoningPaths: reasoningPaths,
                graphPaths: graphPaths,
                rolePrompt: activeRole?.prompt,
                statusCallback: { [weak self] status in
                    self?.analysisStatus = status
                },
                synthesisTokenCallback: { [weak self] token in
                    self?.streamingSynthesis += token
                },
                hypothesesTokenCallback: { [weak self] token in
                    self?.streamingHypotheses += token
                }
            )

            deepAnalysisResult = result
            streamingSynthesis = ""
            streamingHypotheses = ""
            analysisStatus = ""
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
        guard let itemId = historyItem?.id else {
            logger.warning("Cannot save deep analysis: history item has no ID")
            return
        }

        let updatedItem = historyItem?.withDeepAnalysis(result)

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
