import Foundation
import OSLog

/// ViewModel for the GraphRAG query interface.
@Observable
final class GraphRAGViewModel {
    // MARK: - Published State

    var queryText: String = ""
    var isQuerying: Bool = false
    var persistedHistory: [QueryHistoryItem] = []
    var errorMessage: String?

    /// Set after executing a query to trigger navigation to the answer view.
    var pendingNavigationItem: QueryHistoryItem?

    // MARK: - Services

    private let graphRAGService = GraphRAGService()
    private let hypergraphService = HypergraphService()
    private let queryHistoryService = QueryHistoryService()
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

            // Persist to database
            try queryHistoryService.save(response)
            loadHistory()

            // Set the pending navigation item to trigger navigation to the answer view.
            // The most recently saved item will be first in the history.
            if let savedItem = persistedHistory.first, savedItem.query == queryText {
                pendingNavigationItem = savedItem
            }

            logger.info("Query completed successfully")
        } catch {
            logger.error("Query failed: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    /// Clears the current query.
    func clearQuery() {
        queryText = ""
        errorMessage = nil
    }

    /// Loads query history from the database.
    func loadHistory() {
        do {
            persistedHistory = try queryHistoryService.fetchRecent(limit: 50)
        } catch {
            logger.error("Failed to load history: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Deletes a query history item.
    func deleteHistoryItem(_ item: QueryHistoryItem) {
        guard let id = item.id else { return }
        do {
            try queryHistoryService.delete(id: id)
            loadHistory()
        } catch {
            logger.error("Failed to delete history item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Clears the query history.
    func clearHistory() {
        do {
            try queryHistoryService.deleteAll()
            persistedHistory.removeAll()
        } catch {
            logger.error("Failed to clear history: \(error.localizedDescription, privacy: .public)")
        }
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
        "Summarize the key themes across all articles.",
        "I'm CEO of a cloud provider. Generate plausible scenarios for how the top news topics may impact my business."
    ]
}
