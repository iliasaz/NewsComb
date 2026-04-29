import Foundation
import GRDB
import Observation
import OSLog

/// View model for the list of social simulations.
@MainActor
@Observable
final class SimulationListViewModel {

    // MARK: - State

    private(set) var simulations: [SocialSimulation] = []
    private(set) var isLoading = false
    var errorMessage: String?

    // MARK: - Internal

    private let database = Database.current
    private let logger = Logger(subsystem: "com.newscomb", category: "SimulationListViewModel")

    // MARK: - Loading

    func loadSimulations() {
        do {
            simulations = try database.read { db in
                try SocialSimulation
                    .order(SocialSimulation.Columns.createdAt.desc)
                    .fetchAll(db)
            }
        } catch {
            logger.error("Failed to load simulations: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Creation

    /// Creates a new simulation record in "configuring" status.
    func createSimulation(name: String) -> SocialSimulation? {
        let simulation = SocialSimulation(name: name)
        do {
            try database.write { db in
                try simulation.insert(db)
            }
            loadSimulations()
            return simulation
        } catch {
            logger.error("Failed to create simulation: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
            return nil
        }
    }

    // MARK: - Deletion

    func deleteSimulation(_ simulation: SocialSimulation) {
        do {
            try database.write { db in
                // CASCADE deletes agents, posts, interactions, connections, interviews
                try db.execute(
                    sql: "DELETE FROM social_simulation WHERE id = ?",
                    arguments: [simulation.id]
                )
            }

            // Clean up simulation directory
            if let simDir = simulation.simDirectory {
                try? FileManager.default.removeItem(atPath: simDir)
            }

            loadSimulations()
        } catch {
            logger.error("Failed to delete simulation: \(error.localizedDescription, privacy: .public)")
            errorMessage = error.localizedDescription
        }
    }

    var hasSimulations: Bool {
        !simulations.isEmpty
    }
}
