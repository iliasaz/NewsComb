import Foundation
import MCP

/// Lists clusters flagged by the IQR-on-log(size) outlier rule as likely
/// noise pools (absorption buckets, not real themes).
enum MCPIdentifyNoisePoolsTool {
    static func run(arguments: [String: Value]) async -> String {
        await MCPAppCoordinator.shared.identifyNoisePools()
    }
}
