import XCTest
@testable import NewsCombApp

final class MarkdownExportServiceTests: XCTestCase {

    // MARK: - Markdown Generation Tests

    func testArticleToMarkdownIncludesTitle() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test Article Title",
            link: "https://example.com/article",
            author: nil,
            pubDate: nil,
            sourceName: "Test Source",
            content: "Test content"
        )

        XCTAssertTrue(markdown.contains("# Test Article Title"), "Markdown should include title as H1")
    }

    func testArticleToMarkdownIncludesSource() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test",
            link: "https://example.com",
            author: nil,
            pubDate: nil,
            sourceName: "My News Source",
            content: "Content"
        )

        XCTAssertTrue(markdown.contains("**Source:** My News Source"), "Markdown should include source name")
    }

    func testArticleToMarkdownIncludesAuthor() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test",
            link: "https://example.com",
            author: "John Doe",
            pubDate: nil,
            sourceName: "Source",
            content: "Content"
        )

        XCTAssertTrue(markdown.contains("**Author:** John Doe"), "Markdown should include author")
    }

    func testArticleToMarkdownOmitsEmptyAuthor() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test",
            link: "https://example.com",
            author: "",
            pubDate: nil,
            sourceName: "Source",
            content: "Content"
        )

        XCTAssertFalse(markdown.contains("**Author:**"), "Markdown should not include empty author")
    }

    func testArticleToMarkdownIncludesLink() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test",
            link: "https://example.com/my-article",
            author: nil,
            pubDate: nil,
            sourceName: "Source",
            content: "Content"
        )

        XCTAssertTrue(markdown.contains("**Link:** https://example.com/my-article"), "Markdown should include link")
    }

    func testArticleToMarkdownIncludesContent() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test",
            link: "https://example.com",
            author: nil,
            pubDate: nil,
            sourceName: "Source",
            content: "This is the article content."
        )

        XCTAssertTrue(markdown.contains("This is the article content."), "Markdown should include content")
    }

    func testArticleToMarkdownStripsHTMLTags() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test",
            link: "https://example.com",
            author: nil,
            pubDate: nil,
            sourceName: "Source",
            content: "<p>Paragraph content</p><div>More content</div>"
        )

        XCTAssertFalse(markdown.contains("<p>"), "Markdown should strip HTML tags")
        XCTAssertFalse(markdown.contains("</p>"), "Markdown should strip HTML tags")
        XCTAssertTrue(markdown.contains("Paragraph content"), "Content should remain after stripping tags")
    }

    func testArticleToMarkdownHandlesNilContent() {
        let markdown = MarkdownExportService.articleToMarkdown(
            title: "Test",
            link: "https://example.com",
            author: nil,
            pubDate: nil,
            sourceName: "Source",
            content: nil
        )

        XCTAssertTrue(markdown.contains("*No content available*"), "Should show placeholder for nil content")
    }

    // MARK: - Filename Sanitization Tests

    func testSanitizeFilenameRemovesInvalidCharacters() {
        let sanitized = MarkdownExportService.sanitizeFilename("Test: File/Name?")
        XCTAssertFalse(sanitized.contains(":"), "Should remove colon")
        XCTAssertFalse(sanitized.contains("?"), "Should remove question mark")
    }

    func testSanitizeFilenamePreservesValidCharacters() {
        let sanitized = MarkdownExportService.sanitizeFilename("Valid-File_Name 123")
        XCTAssertEqual(sanitized, "Valid-File_Name 123", "Valid characters should be preserved")
    }

    func testSanitizeFilenameTruncatesLongNames() {
        let longName = String(repeating: "a", count: 150)
        let sanitized = MarkdownExportService.sanitizeFilename(longName)
        XCTAssertLessThanOrEqual(sanitized.count, 80, "Filename should be truncated to 80 chars")
    }

    func testSanitizeFilenameHandlesEmptyString() {
        let sanitized = MarkdownExportService.sanitizeFilename("")
        XCTAssertEqual(sanitized, "untitled", "Empty string should return 'untitled'")
    }

    func testSanitizeFilenameTrimsWhitespace() {
        let sanitized = MarkdownExportService.sanitizeFilename("  Test Name  ")
        XCTAssertEqual(sanitized, "Test Name", "Should trim leading and trailing whitespace")
    }

    func testSanitizeFilenameStripsURLProtocol() {
        let sanitized = MarkdownExportService.sanitizeFilename("https://example.com/blog/feed")
        XCTAssertFalse(sanitized.hasPrefix("https"), "Should strip https://")
        XCTAssertFalse(sanitized.contains("://"), "Should not contain ://")
    }

    func testSanitizeFilenameHandlesAWSFeedURL() {
        let sanitized = MarkdownExportService.sanitizeFilename("https://aws.amazon.com/blogs/aws/feed")
        XCTAssertEqual(sanitized, "aws.amazon.com-blogs-aws", "Should produce clean folder name from URL")
    }

    func testSanitizeFilenameRemovesMultipleDashes() {
        let sanitized = MarkdownExportService.sanitizeFilename("test--name---here")
        XCTAssertFalse(sanitized.contains("--"), "Should not contain multiple consecutive dashes")
    }

    // MARK: - Date String Tests

    func testCurrentDateStringFormat() {
        let dateString = MarkdownExportService.currentDateString()
        // Should be in YYYY-MM-DD format
        let pattern = "^\\d{4}-\\d{2}-\\d{2}$"
        let regex = try? NSRegularExpression(pattern: pattern)
        let range = NSRange(dateString.startIndex..., in: dateString)
        let match = regex?.firstMatch(in: dateString, range: range)
        XCTAssertNotNil(match, "Date string should be in YYYY-MM-DD format")
    }
}
