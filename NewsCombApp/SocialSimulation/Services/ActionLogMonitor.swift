import Foundation
import OSLog

/// Actor that polls OASIS JSONL action log files and emits new actions.
///
/// Owns file read offsets as actor-isolated state. Uses `@concurrent`
/// for file I/O to avoid blocking the actor's serialized queue.
actor ActionLogMonitor {

    private let logFiles: [URL]
    private var fileOffsets: [URL: UInt64] = [:]
    private var isMonitoring = false
    private let logger = Logger(subsystem: "com.newscomb", category: "ActionLogMonitor")

    init(logFiles: [URL]) {
        self.logFiles = logFiles
        for file in logFiles {
            fileOffsets[file] = 0
        }
    }

    // MARK: - Public API

    /// Starts monitoring action log files.
    ///
    /// Returns an `AsyncStream` that yields batches of new actions as they
    /// appear in the JSONL files. The stream finishes when a `simulation_end`
    /// event is detected or `stopMonitoring()` is called.
    func startMonitoring() -> AsyncStream<[OasisAction]> {
        isMonitoring = true
        logger.info("Started monitoring \(self.logFiles.count) action log files")

        let monitor = self

        return AsyncStream { continuation in
            continuation.onTermination = { _ in
                Task { await monitor.stopMonitoring() }
            }

            Task {
                while await monitor.isMonitoring {
                    do {
                        try Task.checkCancellation()
                    } catch {
                        break
                    }

                    let actions = await monitor.readNewActions()

                    if !actions.isEmpty {
                        continuation.yield(actions)

                        // Check for simulation end
                        if actions.contains(where: \.isSimulationEnd) {
                            await monitor.logger.info("Detected simulation_end event")
                            break
                        }
                    }

                    try? await Task.sleep(for: .seconds(2))
                }

                continuation.finish()
                await monitor.logger.info("Action log monitoring stopped")
            }
        }
    }

    /// Stops the monitoring loop.
    func stopMonitoring() {
        isMonitoring = false
    }

    /// Whether the monitor is currently active.
    var monitoring: Bool {
        isMonitoring
    }

    // MARK: - File Reading

    /// Reads new actions from all log files since last offsets.
    /// Called from the monitoring task.
    private func readNewActions() async -> [OasisAction] {
        var allActions: [OasisAction] = []

        for file in logFiles {
            let currentOffset = fileOffsets[file] ?? 0
            let result = Self.readActionsFromFile(file: file, offset: currentOffset)

            if result.newOffset > currentOffset {
                fileOffsets[file] = result.newOffset
                allActions.append(contentsOf: result.actions)
            }
        }

        return allActions
    }

    /// Reads new JSONL lines from a file starting at the given byte offset.
    ///
    /// This is a static method (no actor state) so it can safely run
    /// without holding the actor's isolation.
    private static func readActionsFromFile(
        file: URL,
        offset: UInt64
    ) -> (actions: [OasisAction], newOffset: UInt64) {
        guard FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            return ([], offset)
        }

        guard let handle = try? FileHandle(forReadingFrom: file) else {
            return ([], offset)
        }
        defer { try? handle.close() }

        handle.seek(toFileOffset: offset)
        guard let data = try? handle.availableData, !data.isEmpty else {
            return ([], offset)
        }

        let newOffset = offset + UInt64(data.count)

        guard let text = String(data: data, encoding: .utf8) else {
            return ([], newOffset)
        }

        let decoder = JSONDecoder()
        var actions: [OasisAction] = []

        for line in text.split(separator: "\n") where !line.isEmpty {
            guard let lineData = line.data(using: .utf8) else { continue }
            if let action = try? decoder.decode(OasisAction.self, from: lineData) {
                actions.append(action)
            }
        }

        return (actions, newOffset)
    }
}
