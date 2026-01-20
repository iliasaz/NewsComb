import Foundation
import OSLog

/// ViewModel for the GraphRAG query interface.
@Observable
final class GraphRAGViewModel {
    // MARK: - Published State

    var queryText: String = ""
    var isQuerying: Bool = false
    var currentResponse: GraphRAGResponse?
    var queryHistory: [GraphRAGResponse] = []
    var errorMessage: String?

    // MARK: - Services

    private let graphRAGService = GraphRAGService()
    private let hypergraphService = HypergraphService()
    private let logger = Logger(subsystem: "com.newscomb", category: "GraphRAGViewModel")

    // MARK: - Query Execution

    /// Executes a query against the knowledge graph.
    @MainActor
    func executeQuery() async {
        guard !queryText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorMessage = "Please enter a question."
            return
        }

        guard !isQuerying else { return }

        isQuerying = true
        errorMessage = nil

        defer { isQuerying = false }

        do {
            logger.info("Executing GraphRAG query: \(self.queryText, privacy: .public)")
            let response = try await graphRAGService.query(queryText)

            currentResponse = response
            queryHistory.insert(response, at: 0)

            // Keep history manageable
            if queryHistory.count > 20 {
                queryHistory = Array(queryHistory.prefix(20))
            }

            logger.info("Query completed successfully")
        } catch {
            logger.error("Query failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Clears the current query and response.
    func clearQuery() {
        queryText = ""
        currentResponse = nil
        errorMessage = nil
    }

    /// Loads a previous query from history.
    func loadFromHistory(_ response: GraphRAGResponse) {
        queryText = response.query
        currentResponse = response
    }

    /// Clears the query history.
    func clearHistory() {
        queryHistory.removeAll()
    }

    // MARK: - Configuration Check

    /// Checks if the service is properly configured.
    func isConfigured() -> Bool {
        hypergraphService.isConfigured()
    }

    // MARK: - Statistics

    /// Gets current hypergraph statistics.
    func getStatistics() -> HypergraphStatistics? {
        try? hypergraphService.getStatistics()
    }

    // MARK: - Node Navigation

    /// Searches for nodes similar to a text query.
    @MainActor
    func searchNodes(_ query: String) async -> [(nodeId: Int64, label: String, distance: Double)] {
        do {
            return try await hypergraphService.searchSimilarConcepts(query: query, limit: 10)
        } catch {
            logger.error("Node search failed: \(error.localizedDescription, privacy: .public)")
            return []
        }
    }
}

// MARK: - Sample Queries

extension GraphRAGViewModel {
    /// Sample queries to help users get started.
    static let sampleQueries: [String] = [
        "What are the main topics discussed in recent articles?",
        "What companies are mentioned and how are they related?",
        "What events happened recently?",
        "What connections exist between different people mentioned?",
        "Summarize the key themes across all articles."
    ]
}
