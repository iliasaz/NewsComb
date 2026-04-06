import XCTest
@testable import NewsCombApp

@MainActor
final class AnswerExportTests: XCTestCase {

    // MARK: - Helpers

    private func makeHistoryItem(
        query: String = "What is happening?",
        answer: String = "Several events occurred.",
        title: String? = nil,
        sourceArticlesJson: String? = nil,
        synthesizedAnalysis: String? = nil,
        hypotheses: String? = nil
    ) -> QueryHistoryItem {
        QueryHistoryItem(
            id: 1,
            query: query,
            answer: answer,
            title: title,
            relatedNodesJson: nil,
            reasoningPathsJson: nil,
            graphPathsJson: nil,
            sourceArticlesJson: sourceArticlesJson,
            synthesizedAnalysis: synthesizedAnalysis,
            hypotheses: hypotheses,
            analyzedAt: synthesizedAnalysis != nil ? Date() : nil,
            createdAt: Date()
        )
    }

    // MARK: - Export Markdown Tests

    func testExportIncludesQuestionAsTitle() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem(query: "My question"))
        let md = vm.exportMarkdown()
        XCTAssertTrue(md.hasPrefix("# My question\n"))
    }

    func testExportIncludesAnswer() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem(answer: "The answer text."))
        let md = vm.exportMarkdown()
        XCTAssertTrue(md.contains("## Answer\n\nThe answer text."))
    }

    func testExportIncludesDeepAnalysis() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem(
            synthesizedAnalysis: "Synthesized content here.",
            hypotheses: "Hypothesis content here."
        ))
        let md = vm.exportMarkdown()
        XCTAssertTrue(md.contains("## Synthesized Analysis\n\nSynthesized content here."))
        XCTAssertTrue(md.contains("## Hypotheses & Experiments\n\nHypothesis content here."))
    }

    func testExportOmitsDeepAnalysisWhenAbsent() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem())
        let md = vm.exportMarkdown()
        XCTAssertFalse(md.contains("## Synthesized Analysis"))
        XCTAssertFalse(md.contains("## Hypotheses & Experiments"))
    }

    func testExportIncludesSourcesWithLinks() {
        let sourcesJson = """
        [{"id":1,"title":"Article One","link":"https://example.com/one","relevantChunks":[]},\
        {"id":2,"title":"Article Two","link":"https://example.com/two","relevantChunks":[]}]
        """
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem(sourceArticlesJson: sourcesJson))
        let md = vm.exportMarkdown()
        XCTAssertTrue(md.contains("## Sources"))
        XCTAssertTrue(md.contains("- [Article One](https://example.com/one)"))
        XCTAssertTrue(md.contains("- [Article Two](https://example.com/two)"))
    }

    func testExportSourceWithoutLinkFallsBackToPlainText() {
        let sourcesJson = """
        [{"id":1,"title":"No Link Article","relevantChunks":[]}]
        """
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem(sourceArticlesJson: sourcesJson))
        let md = vm.exportMarkdown()
        XCTAssertTrue(md.contains("- No Link Article"))
        XCTAssertFalse(md.contains("[No Link Article]"))
    }

    func testExportOmitsSourcesSectionWhenEmpty() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem())
        let md = vm.exportMarkdown()
        XCTAssertFalse(md.contains("## Sources"))
    }

    // MARK: - Dive Deep Question Tests

    func testDiveDeepQuestionDefaultsToEmpty() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem())
        XCTAssertEqual(vm.diveDeepQuestion, "")
    }

    func testDiveDeepQuestionIsMutable() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem())
        vm.diveDeepQuestion = "Custom follow-up question"
        XCTAssertEqual(vm.diveDeepQuestion, "Custom follow-up question")
    }

    // MARK: - Question Title Tests

    func testQuestionTitleLoadedFromHistory() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem(title: "AI Partnership Trends"))
        XCTAssertEqual(vm.questionTitle, "AI Partnership Trends")
    }

    func testQuestionTitleNilWhenNotInHistory() {
        let vm = AnswerDetailViewModel(historyItem: makeHistoryItem())
        XCTAssertNil(vm.questionTitle)
    }
}
