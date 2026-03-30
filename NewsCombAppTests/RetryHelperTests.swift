import XCTest
@testable import NewsCombApp

final class RetryHelperTests: XCTestCase {

    /// Thread-safe counter for tracking call counts in @Sendable closures.
    private actor Counter {
        var value = 0
        func increment() -> Int {
            value += 1
            return value
        }
    }

    func testSucceedsOnFirstAttempt() async throws {
        let counter = Counter()
        let result = try await withRetry(maxAttempts: 3) {
            await counter.increment()
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        let count = await counter.value
        XCTAssertEqual(count, 1)
    }

    func testRetriesOnTimeout() async throws {
        let counter = Counter()
        let result = try await withRetry(maxAttempts: 3, initialDelay: .milliseconds(10)) {
            let attempt = await counter.increment()
            if attempt < 3 {
                throw URLError(.timedOut)
            }
            return "recovered"
        }
        XCTAssertEqual(result, "recovered")
        let count = await counter.value
        XCTAssertEqual(count, 3)
    }

    func testRetriesOnConnectionLost() async throws {
        let counter = Counter()
        let result = try await withRetry(maxAttempts: 3, initialDelay: .milliseconds(10)) {
            let attempt = await counter.increment()
            if attempt < 2 {
                throw URLError(.networkConnectionLost)
            }
            return "back"
        }
        XCTAssertEqual(result, "back")
        let count = await counter.value
        XCTAssertEqual(count, 2)
    }

    func testDoesNotRetryNonRetryableError() async {
        let counter = Counter()
        do {
            _ = try await withRetry(maxAttempts: 3, initialDelay: .milliseconds(10)) {
                await counter.increment()
                throw URLError(.userAuthenticationRequired)
            }
            XCTFail("Should have thrown")
        } catch {
            let count = await counter.value
            XCTAssertEqual(count, 1, "Should not retry auth errors")
        }
    }

    func testExhaustsAllAttempts() async {
        let counter = Counter()
        do {
            _ = try await withRetry(maxAttempts: 3, initialDelay: .milliseconds(10)) {
                await counter.increment()
                throw URLError(.timedOut)
            }
            XCTFail("Should have thrown")
        } catch {
            let count = await counter.value
            XCTAssertEqual(count, 3, "Should exhaust all attempts")
            XCTAssertTrue(error is URLError)
        }
    }

    func testRespectsMaxAttemptsOne() async {
        let counter = Counter()
        do {
            _ = try await withRetry(maxAttempts: 1, initialDelay: .milliseconds(10)) {
                await counter.increment()
                throw URLError(.timedOut)
            }
            XCTFail("Should have thrown")
        } catch {
            let count = await counter.value
            XCTAssertEqual(count, 1, "maxAttempts=1 means no retries")
        }
    }

    func testDoesNotRetryCancellation() async {
        let counter = Counter()
        do {
            _ = try await withRetry(maxAttempts: 3, initialDelay: .milliseconds(10)) {
                await counter.increment()
                throw CancellationError()
            }
            XCTFail("Should have thrown")
        } catch {
            let count = await counter.value
            XCTAssertEqual(count, 1, "Should not retry cancellation")
            XCTAssertTrue(error is CancellationError)
        }
    }

    func testRetries429RateLimit() async throws {
        let counter = Counter()
        let result = try await withRetry(maxAttempts: 3, initialDelay: .milliseconds(10)) {
            let attempt = await counter.increment()
            if attempt < 2 {
                throw NSError(domain: "test", code: 429, userInfo: [
                    NSLocalizedDescriptionKey: "429 Too Many Requests"
                ])
            }
            return "ok"
        }
        XCTAssertEqual(result, "ok")
        let count = await counter.value
        XCTAssertEqual(count, 2)
    }
}
