import Foundation

/// Bucketing of raw edge verbs into a fixed set of relation families
/// for use as a one-hot component in event vectors.
///
/// The family set is designed to capture the dominant relation types
/// in a tech/business news corpus without being overly granular.
enum RelationFamily: Int, CaseIterable, Sendable {
    case causeEffect = 0
    case association
    case competition
    case partnership
    case acquisitionInvestment
    case regulationLegal
    case securityIncident
    case pricingCost
    case performanceBenchmark
    case hiringLayoffs
    case productLaunch
    case other

    /// Number of families (dimension of the one-hot vector).
    static let count = Self.allCases.count

    /// Human-readable label for UI display.
    var label: String {
        switch self {
        case .causeEffect: "Cause & Effect"
        case .association: "Association"
        case .competition: "Competition"
        case .partnership: "Partnership"
        case .acquisitionInvestment: "Acquisition & Investment"
        case .regulationLegal: "Regulation & Legal"
        case .securityIncident: "Security Incident"
        case .pricingCost: "Pricing & Cost"
        case .performanceBenchmark: "Performance & Benchmark"
        case .hiringLayoffs: "Hiring & Layoffs"
        case .productLaunch: "Product Launch"
        case .other: "Other"
        }
    }

    /// One-hot vector representation.
    var oneHot: [Float] {
        var vec = [Float](repeating: 0, count: Self.count)
        vec[rawValue] = 1.0
        return vec
    }

    // MARK: - Verb Classification

    /// Keywords that indicate each relation family.
    /// Checked against the lowercased verb using `localizedStandardContains`.
    private static let familyKeywords: [(RelationFamily, [String])] = [
        (.causeEffect, [
            "cause", "result in", "lead to", "leads to", "led to",
            "trigger", "enable",
            "prevent", "block", "reduce", "increase", "impact",
            "affect", "disrupt", "transform", "drive", "accelerate",
        ]),
        (.partnership, [
            "partner", "collaborate", "team up", "ally", "join",
            "integrate", "work with", "cooperate", "support",
        ]),
        (.acquisitionInvestment, [
            "acquire", "buy", "purchase", "invest", "fund",
            "merge", "raise", "sell", "divest", "ipo",
        ]),
        (.competition, [
            "compete", "rival", "challenge", "outperform", "surpass",
            "overtake", "beat", "versus", "alternative",
        ]),
        (.regulationLegal, [
            "regulate", "ban", "approve", "fine", "sue",
            "comply", "enforce", "legislat", "sanction", "antitrust",
            "patent", "licens", "lawsuit",
        ]),
        (.securityIncident, [
            "hack", "breach", "attack", "vulnerab", "exploit",
            "malware", "ransomware", "phish", "compromis", "leak",
        ]),
        (.pricingCost, [
            "price", "cost", "fee", "tariff", "discount",
            "revenue", "profit", "margin", "valuation", "billion",
            "million", "worth",
        ]),
        (.performanceBenchmark, [
            "benchmark", "perform", "test", "evaluat", "score",
            "speed", "latency", "throughput", "accuracy", "efficien",
        ]),
        (.hiringLayoffs, [
            "hire", "recruit", "layoff", "lay off", "laid off",
            "fire",
            "restructur", "downsize", "appoint", "resign", "ceo",
        ]),
        (.productLaunch, [
            "launch", "release", "announc", "unveil", "introduce",
            "debut", "ship", "deploy", "roll out", "open source",
        ]),
        (.association, [
            "use", "run", "has", "is", "include", "contain",
            "feature", "offer", "provide", "consist",
        ]),
    ]

    /// Classifies a raw verb string into a relation family.
    static func classify(_ verb: String) -> RelationFamily {
        let lowered = verb.lowercased()

        for (family, keywords) in familyKeywords {
            for keyword in keywords {
                if lowered.localizedStandardContains(keyword) {
                    return family
                }
            }
        }

        return .other
    }
}
