import Foundation

/// Status of a social simulation, used for AsyncStream updates to the UI.
enum SimulationStatus: Sendable, Equatable {
    case idle
    case generatingProfiles(progress: Double)
    case exportingToOasis
    case launching
    case running(round: Int, total: Int)
    case waitingForInterviews
    case completed
    case failed(String)

    /// Whether the simulation subprocess is actively working (show spinner).
    var isProcessing: Bool {
        switch self {
        case .generatingProfiles, .exportingToOasis, .launching, .running:
            true
        default:
            false
        }
    }

    /// Whether the simulation is still alive (processing or waiting for interaction).
    var isActive: Bool {
        switch self {
        case .generatingProfiles, .exportingToOasis, .launching, .running, .waitingForInterviews:
            true
        default:
            false
        }
    }

    /// Whether the simulation has finished (successfully or not).
    var isDone: Bool {
        switch self {
        case .completed, .waitingForInterviews:
            true
        default:
            false
        }
    }

    var displayText: String {
        switch self {
        case .idle:
            "Ready"
        case .generatingProfiles(let progress):
            "Generating profiles (\(Int(progress * 100))%)"
        case .exportingToOasis:
            "Exporting to OASIS"
        case .launching:
            "Launching simulation"
        case .running(let round, let total):
            "Running round \(round)/\(total)"
        case .waitingForInterviews:
            "Simulation complete — interviews available"
        case .completed:
            "Completed"
        case .failed(let message):
            "Failed: \(message)"
        }
    }
}
