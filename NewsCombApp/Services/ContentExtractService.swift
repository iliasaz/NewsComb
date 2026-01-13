import Foundation
import PostlightSwift

/// Service for extracting full article content from URLs using the Postlight parser
struct ContentExtractService {
    private let parser = Parser()

    /// Extract full content from an article URL as Markdown
    /// - Parameter articleURL: The URL of the article to extract
    /// - Returns: The extracted content as Markdown, or nil if extraction failed
    @concurrent
    func extractContent(from articleURL: String) async -> String? {
        guard let url = URL(string: articleURL) else {
            return nil
        }

        do {
            let options = ParserOptions(contentType: .markdown)
            let article = try await parser.parse(url: url, options: options)
            return article.content
        } catch {
            print("Content extraction failed for \(articleURL): \(error.localizedDescription)")
            return nil
        }
    }

    /// Extract full article with metadata from a URL
    /// - Parameter articleURL: The URL of the article to extract
    /// - Returns: The parsed article with metadata, or nil if extraction failed
    @concurrent
    func extractArticle(from articleURL: String) async -> ParsedArticle? {
        guard let url = URL(string: articleURL) else {
            return nil
        }

        do {
            let options = ParserOptions(contentType: .markdown)
            let article = try await parser.parse(url: url, options: options)
            return article
        } catch {
            print("Article extraction failed for \(articleURL): \(error.localizedDescription)")
            return nil
        }
    }

    /// Extract content from provided HTML
    /// - Parameters:
    ///   - html: The HTML content to parse
    ///   - url: The source URL (used for resolving relative links)
    /// - Returns: The extracted content as Markdown, or nil if extraction failed
    @concurrent
    func extractContent(from html: String, url: String) async -> String? {
        guard let sourceURL = URL(string: url) else {
            return nil
        }

        do {
            let options = ParserOptions(contentType: .markdown)
            let article = try await parser.parse(html: html, url: sourceURL, options: options)
            return article.content
        } catch {
            print("HTML extraction failed: \(error.localizedDescription)")
            return nil
        }
    }
}

/// Extension to expose extracted article metadata
extension ParsedArticle {
    /// Returns the estimated reading time in minutes (assuming 200 words per minute)
    var readingTimeMinutes: Int {
        guard wordCount > 0 else { return 0 }
        return max(1, wordCount / 200)
    }
}
