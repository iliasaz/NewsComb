import Foundation

/// Ranked entity for cluster theme display.
struct MCPRankedEntity: Codable {
    let label: String
    let score: Double
}

/// Ranked relationship family for cluster theme display.
struct MCPRankedFamily: Codable {
    let family: String
    let count: Int
}
