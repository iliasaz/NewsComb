import Foundation
import OSLog
import PostlightSwift

/// Result of content extraction including the final URL after redirects
struct ExtractionResult {
    let content: String?
    let finalURL: String?
}

/// Service for extracting full article content from URLs using the Postlight parser
struct ContentExtractService {
    private let parser = Parser()
    private let logger = Logger(subsystem: "com.newscomb", category: "ContentExtractService")

    /// Shared URL session configured like NetNewsWire - ephemeral with no cookies
    private static let urlSession: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.httpMaximumConnectionsPerHost = 2
        config.timeoutIntervalForRequest = 10  // Reduced from 30 to fail faster
        config.timeoutIntervalForResource = 15  // Reduced from 60 to fail faster
        return URLSession(configuration: config)
    }()

    /// User-Agent string - identifies as RSS reader (like NetNewsWire does)
    private static let userAgent = "NewsComb/1.0 (RSS Reader; macOS)"

    /// Extract full content from an article URL as Markdown
    /// - Parameter articleURL: The URL of the article to extract
    /// - Returns: The extracted content as Markdown, or nil if extraction failed
    @concurrent
    func extractContent(from articleURL: String) async -> String? {
        let result = await extractContentWithFinalURL(from: articleURL)
        return result.content
    }

    /// Extract full content from an article URL, following redirects
    /// - Parameter articleURL: The URL of the article to extract
    /// - Returns: ExtractionResult containing the content and final URL after redirects
    @concurrent
    func extractContentWithFinalURL(from articleURL: String) async -> ExtractionResult {
        guard let url = URL(string: articleURL) else {
            return ExtractionResult(content: nil, finalURL: nil)
        }

        // Fetch HTML with proper User-Agent to avoid bot detection
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        request.timeoutInterval = 10  // Fail fast on unresponsive sites

        do {
            let (data, response) = try await Self.urlSession.data(for: request)

            // Get the final URL after redirects
            let finalURL = (response as? HTTPURLResponse)?.url ?? url

            // Check if we got valid HTML
            guard let html = String(data: data, encoding: .utf8) else {
                logger.error("Content extraction failed for \(articleURL, privacy: .public): Could not decode response as UTF-8")
                return ExtractionResult(content: nil, finalURL: finalURL.absoluteString)
            }

            // Parse the HTML content
            let options = ParserOptions(contentType: .markdown)
            let article = try await parser.parse(html: html, url: finalURL, options: options)
            return ExtractionResult(content: article.content, finalURL: finalURL.absoluteString)
        } catch {
            logger.error("Content extraction failed for \(articleURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return ExtractionResult(content: nil, finalURL: nil)
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
            logger.error("Article extraction failed for \(articleURL, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Fetch raw README.md directly from a GitHub repository.
    /// This is more efficient than parsing HTML since READMEs are already Markdown.
    /// - Parameter repoURL: A GitHub repository URL (e.g., "https://github.com/owner/repo")
    /// - Returns: The raw README content, or nil if fetch failed
    @concurrent
    func fetchGitHubReadme(from repoURL: String) async -> String? {
        // Parse GitHub URL to extract owner and repo
        guard let url = URL(string: repoURL),
              url.host == "github.com" || url.host == "www.github.com" else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else {
            return nil
        }

        let owner = pathComponents[0]
        let repo = pathComponents[1]

        // Try common README filenames in order of likelihood
        let readmeVariants = [
            "README.md",
            "readme.md",
            "Readme.md",
            "README.MD",
            "README.rst",
            "README.txt",
            "README"
        ]

        for filename in readmeVariants {
            // Use HEAD ref to automatically resolve to default branch
            let rawURL = "https://raw.githubusercontent.com/\(owner)/\(repo)/HEAD/\(filename)"

            guard let url = URL(string: rawURL) else { continue }

            var request = URLRequest(url: url)
            request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
            request.timeoutInterval = 10

            do {
                let (data, response) = try await Self.urlSession.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse,
                      httpResponse.statusCode == 200 else {
                    continue  // Try next variant
                }

                guard let content = String(data: data, encoding: .utf8),
                      !content.isEmpty else {
                    continue
                }

                logger.info("Fetched GitHub README from \(rawURL, privacy: .public)")
                return content
            } catch {
                continue  // Try next variant
            }
        }

        logger.debug("Could not fetch README for GitHub repo: \(repoURL, privacy: .public)")
        return nil
    }

    /// Check if a URL is a GitHub repository URL
    /// - Parameter url: The URL to check
    /// - Returns: true if it's a GitHub repo URL (not a file, issue, PR, etc.)
    static func isGitHubRepoURL(_ url: String) -> Bool {
        guard let parsed = URL(string: url),
              parsed.host == "github.com" || parsed.host == "www.github.com" else {
            return false
        }

        let pathComponents = parsed.pathComponents.filter { $0 != "/" }

        // A repo URL has exactly 2 path components: owner/repo
        // URLs like /owner/repo/issues or /owner/repo/blob/... have more
        return pathComponents.count == 2
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
            logger.error("HTML extraction failed: \(error.localizedDescription, privacy: .public)")
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
