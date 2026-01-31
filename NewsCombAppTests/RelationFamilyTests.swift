import XCTest
@testable import NewsCombApp

final class RelationFamilyTests: XCTestCase {

    // MARK: - One-Hot Encoding

    func testOneHotLength() {
        for family in RelationFamily.allCases {
            XCTAssertEqual(family.oneHot.count, RelationFamily.count)
        }
    }

    func testOneHotSingleActivation() {
        for family in RelationFamily.allCases {
            let hot = family.oneHot
            let activeCount = hot.filter { $0 == 1.0 }.count
            XCTAssertEqual(activeCount, 1, "Family \(family.label) should have exactly one active bit")
        }
    }

    func testOneHotPositionMatchesRawValue() {
        for family in RelationFamily.allCases {
            let hot = family.oneHot
            XCTAssertEqual(hot[family.rawValue], 1.0,
                           "Active bit for \(family.label) should be at index \(family.rawValue)")
        }
    }

    func testFamilyCount() {
        XCTAssertEqual(RelationFamily.count, 12)
        XCTAssertEqual(RelationFamily.allCases.count, 12)
    }

    // MARK: - Verb Classification

    func testClassifyCauseEffect() {
        XCTAssertEqual(RelationFamily.classify("caused"), .causeEffect)
        XCTAssertEqual(RelationFamily.classify("leads to"), .causeEffect)
        XCTAssertEqual(RelationFamily.classify("triggered"), .causeEffect)
        XCTAssertEqual(RelationFamily.classify("disrupted"), .causeEffect)
    }

    func testClassifyPartnership() {
        XCTAssertEqual(RelationFamily.classify("partnered with"), .partnership)
        XCTAssertEqual(RelationFamily.classify("collaborates"), .partnership)
        XCTAssertEqual(RelationFamily.classify("integrated with"), .partnership)
    }

    func testClassifyAcquisition() {
        XCTAssertEqual(RelationFamily.classify("acquired"), .acquisitionInvestment)
        XCTAssertEqual(RelationFamily.classify("invested in"), .acquisitionInvestment)
        XCTAssertEqual(RelationFamily.classify("purchased"), .acquisitionInvestment)
        XCTAssertEqual(RelationFamily.classify("merged with"), .acquisitionInvestment)
    }

    func testClassifyCompetition() {
        XCTAssertEqual(RelationFamily.classify("competes with"), .competition)
        XCTAssertEqual(RelationFamily.classify("rivals"), .competition)
        XCTAssertEqual(RelationFamily.classify("outperformed"), .competition)
    }

    func testClassifyRegulation() {
        XCTAssertEqual(RelationFamily.classify("regulated"), .regulationLegal)
        XCTAssertEqual(RelationFamily.classify("fined"), .regulationLegal)
        XCTAssertEqual(RelationFamily.classify("sued"), .regulationLegal)
        XCTAssertEqual(RelationFamily.classify("antitrust action"), .regulationLegal)
    }

    func testClassifySecurity() {
        XCTAssertEqual(RelationFamily.classify("hacked"), .securityIncident)
        XCTAssertEqual(RelationFamily.classify("data breach"), .securityIncident)
        XCTAssertEqual(RelationFamily.classify("exploited vulnerability"), .securityIncident)
    }

    func testClassifyPricing() {
        XCTAssertEqual(RelationFamily.classify("priced at"), .pricingCost)
        XCTAssertEqual(RelationFamily.classify("costs"), .pricingCost)
        XCTAssertEqual(RelationFamily.classify("worth billions"), .pricingCost)
    }

    func testClassifyPerformance() {
        XCTAssertEqual(RelationFamily.classify("benchmarked"), .performanceBenchmark)
        XCTAssertEqual(RelationFamily.classify("evaluated"), .performanceBenchmark)
        XCTAssertEqual(RelationFamily.classify("scored"), .performanceBenchmark)
    }

    func testClassifyHiring() {
        XCTAssertEqual(RelationFamily.classify("hired"), .hiringLayoffs)
        XCTAssertEqual(RelationFamily.classify("laid off"), .hiringLayoffs)
        XCTAssertEqual(RelationFamily.classify("appointed new CEO"), .hiringLayoffs)
    }

    func testClassifyProductLaunch() {
        XCTAssertEqual(RelationFamily.classify("launched"), .productLaunch)
        XCTAssertEqual(RelationFamily.classify("released"), .productLaunch)
        XCTAssertEqual(RelationFamily.classify("announced"), .productLaunch)
        XCTAssertEqual(RelationFamily.classify("open sourced"), .productLaunch)
    }

    func testClassifyAssociation() {
        XCTAssertEqual(RelationFamily.classify("uses"), .association)
        XCTAssertEqual(RelationFamily.classify("includes"), .association)
        XCTAssertEqual(RelationFamily.classify("features"), .association)
    }

    func testClassifyOther() {
        XCTAssertEqual(RelationFamily.classify("xyz unknown verb"), .other)
        XCTAssertEqual(RelationFamily.classify(""), .other)
    }

    func testClassifyCaseInsensitive() {
        XCTAssertEqual(RelationFamily.classify("PARTNERED WITH"), .partnership)
        XCTAssertEqual(RelationFamily.classify("Acquired"), .acquisitionInvestment)
        XCTAssertEqual(RelationFamily.classify("LAUNCHED"), .productLaunch)
    }

    // MARK: - Labels

    func testAllFamiliesHaveLabels() {
        for family in RelationFamily.allCases {
            XCTAssertFalse(family.label.isEmpty, "Family at rawValue \(family.rawValue) should have a label")
        }
    }

    func testLabelsAreUnique() {
        let labels = RelationFamily.allCases.map(\.label)
        XCTAssertEqual(Set(labels).count, labels.count, "All family labels should be unique")
    }
}
