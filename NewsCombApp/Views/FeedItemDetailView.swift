import SwiftUI
#if canImport(WebKit)
import WebKit
#endif

struct FeedItemDetailView: View {
    let item: FeedItemDisplay
    @State private var showingShareSheet = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                headerSection

                Divider()

                contentSection
            }
            .padding()
        }
        .navigationTitle("Article")
        #if os(macOS)
        .navigationSubtitle(item.sourceName)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if let url = URL(string: item.link) {
                    Link(destination: url) {
                        Label("Open in Browser", systemImage: "safari")
                    }

                    ShareLink(item: url) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(item.title)
                .font(.title)
                .bold()

            HStack {
                Label(item.sourceName, systemImage: "newspaper")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)

                Spacer()

                if let date = item.pubDate {
                    Text(date, style: .date)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if let author = item.author, !author.isEmpty {
                Label(author, systemImage: "person")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }

            if !item.hasFullContent {
                HStack {
                    Image(systemName: "info.circle")
                    Text("Full article content not available. Showing summary.")
                }
                .font(.caption)
                .foregroundStyle(.orange)
                .padding(8)
                .background(.orange.opacity(0.1))
                .clipShape(.rect(cornerRadius: 8))
            }
        }
    }

    private var contentSection: some View {
        Group {
            if let fullContent = item.fullContent, !fullContent.isEmpty {
                // Full content is now Markdown from ContentExtractService
                MarkdownContentView(markdown: fullContent)
            } else if let description = item.rssDescription, !description.isEmpty {
                // RSS description is still HTML
                HTMLContentView(html: description)
            } else {
                Text("No content available.")
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
    }
}

/// Renders Markdown content by converting to HTML and displaying in a WebView
struct MarkdownContentView: View {
    let markdown: String

    var body: some View {
        #if os(macOS)
        WebViewRepresentable(html: styledHTML)
            .frame(minHeight: 400)
        #else
        // For iOS, use SwiftUI's basic Markdown support
        Text(LocalizedStringKey(markdown))
            .font(.body)
        #endif
    }

    private var styledHTML: String {
        let htmlContent = markdownToHTML(markdown)
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                    font-size: 16px;
                    line-height: 1.6;
                    color: #333;
                    max-width: 100%;
                    padding: 0;
                    margin: 0;
                    background: transparent;
                }
                @media (prefers-color-scheme: dark) {
                    body {
                        color: #e0e0e0;
                        background: transparent;
                    }
                    a { color: #6eb5ff; }
                }
                img {
                    max-width: 100%;
                    height: auto;
                    border-radius: 8px;
                }
                a {
                    color: #007aff;
                    text-decoration: none;
                }
                a:hover {
                    text-decoration: underline;
                }
                pre {
                    background: #f4f4f4;
                    padding: 12px;
                    border-radius: 8px;
                    overflow-x: auto;
                    font-family: 'SF Mono', Menlo, monospace;
                    font-size: 14px;
                }
                code {
                    background: #f4f4f4;
                    padding: 2px 6px;
                    border-radius: 4px;
                    font-family: 'SF Mono', Menlo, monospace;
                    font-size: 14px;
                }
                pre code {
                    background: none;
                    padding: 0;
                }
                @media (prefers-color-scheme: dark) {
                    pre, code {
                        background: #2d2d2d;
                    }
                    pre code {
                        background: none;
                    }
                }
                blockquote {
                    border-left: 4px solid #ddd;
                    margin-left: 0;
                    padding-left: 16px;
                    color: #666;
                }
                @media (prefers-color-scheme: dark) {
                    blockquote {
                        border-left-color: #555;
                        color: #aaa;
                    }
                }
                h1, h2, h3, h4, h5, h6 {
                    margin-top: 24px;
                    margin-bottom: 12px;
                }
                h1 { font-size: 1.8em; }
                h2 { font-size: 1.5em; }
                h3 { font-size: 1.3em; }
                p {
                    margin-bottom: 16px;
                }
                ul, ol {
                    padding-left: 24px;
                    margin-bottom: 16px;
                }
                li {
                    margin-bottom: 8px;
                }
                hr {
                    border: none;
                    border-top: 1px solid #ddd;
                    margin: 24px 0;
                }
                @media (prefers-color-scheme: dark) {
                    hr {
                        border-top-color: #555;
                    }
                }
                table {
                    border-collapse: collapse;
                    width: 100%;
                    margin-bottom: 16px;
                }
                th, td {
                    border: 1px solid #ddd;
                    padding: 8px 12px;
                    text-align: left;
                }
                th {
                    background: #f4f4f4;
                }
                @media (prefers-color-scheme: dark) {
                    th, td {
                        border-color: #555;
                    }
                    th {
                        background: #2d2d2d;
                    }
                }
            </style>
        </head>
        <body>
            \(htmlContent)
        </body>
        </html>
        """
    }

    /// Convert Markdown to HTML with basic formatting support
    private func markdownToHTML(_ markdown: String) -> String {
        var html = markdown

        // Helper to apply regex replacement
        func replace(pattern: String, with template: String, options: NSRegularExpression.Options = []) {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: options) else { return }
            let range = NSRange(html.startIndex..., in: html)
            html = regex.stringByReplacingMatches(in: html, options: [], range: range, withTemplate: template)
        }

        // Code blocks (fenced with ```)
        replace(pattern: "```([\\s\\S]*?)```", with: "<pre><code>$1</code></pre>")

        // Inline code
        replace(pattern: "`([^`]+)`", with: "<code>$1</code>")

        // Headers (process from h6 to h1 to avoid conflicts)
        replace(pattern: "^#{6}\\s+(.+)$", with: "<h6>$1</h6>", options: .anchorsMatchLines)
        replace(pattern: "^#{5}\\s+(.+)$", with: "<h5>$1</h5>", options: .anchorsMatchLines)
        replace(pattern: "^#{4}\\s+(.+)$", with: "<h4>$1</h4>", options: .anchorsMatchLines)
        replace(pattern: "^#{3}\\s+(.+)$", with: "<h3>$1</h3>", options: .anchorsMatchLines)
        replace(pattern: "^#{2}\\s+(.+)$", with: "<h2>$1</h2>", options: .anchorsMatchLines)
        replace(pattern: "^#\\s+(.+)$", with: "<h1>$1</h1>", options: .anchorsMatchLines)

        // Bold and italic (process longer patterns first)
        replace(pattern: "\\*\\*\\*(.+?)\\*\\*\\*", with: "<strong><em>$1</em></strong>")
        replace(pattern: "\\*\\*(.+?)\\*\\*", with: "<strong>$1</strong>")
        replace(pattern: "\\*(.+?)\\*", with: "<em>$1</em>")
        replace(pattern: "___(.+?)___", with: "<strong><em>$1</em></strong>")
        replace(pattern: "__(.+?)__", with: "<strong>$1</strong>")
        replace(pattern: "_(.+?)_", with: "<em>$1</em>")

        // Images (before links)
        replace(pattern: "!\\[([^\\]]*)\\]\\(([^)]+)\\)", with: "<img src=\"$2\" alt=\"$1\">")

        // Links
        replace(pattern: "\\[([^\\]]+)\\]\\(([^)]+)\\)", with: "<a href=\"$2\">$1</a>")

        // Blockquotes
        replace(pattern: "^>\\s+(.+)$", with: "<blockquote>$1</blockquote>", options: .anchorsMatchLines)

        // Horizontal rules
        replace(pattern: "^---+$", with: "<hr>", options: .anchorsMatchLines)
        replace(pattern: "^\\*\\*\\*+$", with: "<hr>", options: .anchorsMatchLines)

        // Unordered lists
        replace(pattern: "^[\\*\\-]\\s+(.+)$", with: "<li>$1</li>", options: .anchorsMatchLines)

        // Ordered lists
        replace(pattern: "^\\d+\\.\\s+(.+)$", with: "<li>$1</li>", options: .anchorsMatchLines)

        // Wrap consecutive <li> elements in <ul>
        replace(pattern: "(<li>.*?</li>\\s*)+", with: "<ul>$0</ul>", options: .dotMatchesLineSeparators)

        // Paragraphs - wrap non-tagged text blocks
        let paragraphs = html.components(separatedBy: "\n\n")
        html = paragraphs.map { paragraph in
            let trimmed = paragraph.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { return "" }
            // Don't wrap if already has block-level tags
            if trimmed.hasPrefix("<h") || trimmed.hasPrefix("<p") || trimmed.hasPrefix("<ul") ||
               trimmed.hasPrefix("<ol") || trimmed.hasPrefix("<blockquote") || trimmed.hasPrefix("<pre") ||
               trimmed.hasPrefix("<hr") || trimmed.hasPrefix("<div") || trimmed.hasPrefix("<table") {
                return trimmed
            }
            return "<p>\(trimmed)</p>"
        }.joined(separator: "\n")

        // Line breaks within paragraphs (single newlines that aren't before tags)
        replace(pattern: "\\n(?!<)", with: "<br>\n")

        return html
    }
}

/// Renders HTML content directly in a WebView
struct HTMLContentView: View {
    let html: String

    var body: some View {
        #if os(macOS)
        WebViewRepresentable(html: styledHTML)
            .frame(minHeight: 400)
        #else
        // For iOS, use a simpler text-based approach or WebView
        Text(strippedText)
            .font(.body)
        #endif
    }

    private var styledHTML: String {
        """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <meta name="viewport" content="width=device-width, initial-scale=1.0">
            <style>
                body {
                    font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif;
                    font-size: 16px;
                    line-height: 1.6;
                    color: #333;
                    max-width: 100%;
                    padding: 0;
                    margin: 0;
                    background: transparent;
                }
                @media (prefers-color-scheme: dark) {
                    body {
                        color: #e0e0e0;
                        background: transparent;
                    }
                    a { color: #6eb5ff; }
                }
                img {
                    max-width: 100%;
                    height: auto;
                    border-radius: 8px;
                }
                a {
                    color: #007aff;
                    text-decoration: none;
                }
                a:hover {
                    text-decoration: underline;
                }
                pre, code {
                    background: #f4f4f4;
                    padding: 2px 6px;
                    border-radius: 4px;
                    font-family: 'SF Mono', Menlo, monospace;
                    font-size: 14px;
                }
                @media (prefers-color-scheme: dark) {
                    pre, code {
                        background: #2d2d2d;
                    }
                }
                blockquote {
                    border-left: 4px solid #ddd;
                    margin-left: 0;
                    padding-left: 16px;
                    color: #666;
                }
                @media (prefers-color-scheme: dark) {
                    blockquote {
                        border-left-color: #555;
                        color: #aaa;
                    }
                }
                h1, h2, h3, h4, h5, h6 {
                    margin-top: 24px;
                    margin-bottom: 12px;
                }
                p {
                    margin-bottom: 16px;
                }
            </style>
        </head>
        <body>
            \(html)
        </body>
        </html>
        """
    }

    private var strippedText: String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#if os(macOS)
struct WebViewRepresentable: NSViewRepresentable {
    let html: String

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.preferences.isTextInteractionEnabled = true

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.setValue(false, forKey: "drawsBackground")
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        webView.loadHTMLString(html, baseURL: nil)
    }
}
#endif

#Preview {
    NavigationStack {
        FeedItemDetailView(item: FeedItemDisplay(
            id: 1,
            title: "Sample Article Title That Is Quite Long",
            sourceName: "TechCrunch",
            link: "https://example.com/article",
            pubDate: Date(),
            rssDescription: "This is a sample description of the article.",
            fullContent: """
            # Sample Markdown Article

            This is a **bold** statement and this is *italic*.

            ## Code Example

            Here's some `inline code` and a code block:

            ```
            func hello() {
                print("Hello, World!")
            }
            ```

            ## Lists

            - Item one
            - Item two
            - Item three

            > This is a blockquote

            [Link to example](https://example.com)
            """,
            author: "John Doe",
            isRead: false
        ))
    }
}
