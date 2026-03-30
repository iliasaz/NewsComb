import Foundation
import OSLog

/// Retries an async throwing operation with exponential backoff.
///
/// Retries on network errors (timeouts, connection failures) and HTTP 429
/// rate limit responses. Non-retryable errors (auth failures, decoding errors)
/// are thrown immediately without retry.
///
/// - Parameters:
///   - maxAttempts: Maximum number of attempts (including the first). Default 4.
///   - initialDelay: Delay before the first retry. Default 2 seconds.
///   - maxDelay: Maximum delay between retries. Default 30 seconds.
///   - operation: The async operation to retry.
/// - Returns: The result of the operation.
func withRetry<T: Sendable>(
    maxAttempts: Int = 4,
    initialDelay: Duration = .seconds(2),
    maxDelay: Duration = .seconds(30),
    logger: Logger? = nil,
    operation: @Sendable () async throws -> T
) async throws -> T {
    var lastError: Error?
    var delay = initialDelay

    for attempt in 1...maxAttempts {
        do {
            return try await operation()
        } catch {
            lastError = error

            // Don't retry on cancellation
            if error is CancellationError { throw error }

            // Don't retry on non-retryable errors
            guard isRetryable(error) else { throw error }

            // Don't retry if this was the last attempt
            guard attempt < maxAttempts else { break }

            logger?.warning("Attempt \(attempt)/\(maxAttempts) failed, retrying in \(delay): \(error.localizedDescription, privacy: .public)")

            try await Task.sleep(for: delay)

            // Exponential backoff with jitter
            let jitter = Double.random(in: 0.8...1.2)
            delay = min(maxDelay, delay * 2 * jitter)
        }
    }

    throw lastError!
}

/// Determines whether an error is worth retrying.
private func isRetryable(_ error: Error) -> Bool {
    let description = String(describing: error)

    // Network-level errors (timeout, connection reset, etc.)
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet,
             .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
             .secureConnectionFailed:
            return true
        default:
            return false
        }
    }

    // HTTP 429 (rate limit) — often wrapped in provider-specific errors
    if description.contains("429") || description.lowercased().contains("rate limit") {
        return true
    }

    // HTTP 502/503/504 (server overload)
    if description.contains("502") || description.contains("503") || description.contains("504") {
        return true
    }

    // Network-level timeout messages from the OS
    if description.contains("timed out") || description.contains("Operation timed out") {
        return true
    }

    // Connection failures from the LLM provider
    if description.contains("connectionFailed") {
        return true
    }

    return false
}
