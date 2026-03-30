import XCTest
@testable import NewsCombApp

/// Tests the retry-pass pattern: fail fast, collect failures, retry in subsequent passes.
final class RetryQueueTests: XCTestCase {

    /// Simulates the processing loop's retry pass behavior.
    func testFailedItemsRetriedInSubsequentPasses() async {
        let items = Array(0..<10)
        let failOnFirstPass: Set<Int> = [2, 5, 7] // These fail on pass 0
        let failOnSecondPass: Set<Int> = [7]       // This one also fails on pass 1

        var processedItems: Set<Int> = []
        var totalAttempts: [Int: Int] = [:] // item → attempt count
        let maxRetryPasses = 3

        var pending = items
        for pass in 0...maxRetryPasses {
            guard !pending.isEmpty else { break }

            var failedThisPass: [Int] = []
            for item in pending {
                totalAttempts[item, default: 0] += 1
                let shouldFail = (pass == 0 && failOnFirstPass.contains(item))
                    || (pass == 1 && failOnSecondPass.contains(item))

                if shouldFail {
                    failedThisPass.append(item)
                } else {
                    processedItems.insert(item)
                }
            }
            pending = failedThisPass
        }

        // All items should eventually succeed
        XCTAssertEqual(processedItems.count, 10, "All items should be processed")
        XCTAssertTrue(pending.isEmpty, "No items should be left pending")

        // Items that didn't fail should have 1 attempt
        XCTAssertEqual(totalAttempts[0], 1)
        XCTAssertEqual(totalAttempts[1], 1)

        // Items that failed once should have 2 attempts
        XCTAssertEqual(totalAttempts[2], 2)
        XCTAssertEqual(totalAttempts[5], 2)

        // Item 7 failed twice → 3 attempts
        XCTAssertEqual(totalAttempts[7], 3)
    }

    func testPermanentFailuresExhaustRetries() async {
        let items = [1, 2, 3]
        let alwaysFails: Set<Int> = [2]
        let maxRetryPasses = 3

        var processedItems: Set<Int> = []
        var pending = items

        for pass in 0...maxRetryPasses {
            guard !pending.isEmpty else { break }
            var failedThisPass: [Int] = []
            for item in pending {
                if alwaysFails.contains(item) {
                    failedThisPass.append(item)
                } else {
                    processedItems.insert(item)
                }
            }
            pending = failedThisPass
        }

        XCTAssertEqual(processedItems, [1, 3], "Non-failing items should succeed")
        XCTAssertEqual(pending, [2], "Permanently failing item should remain")
    }
}
