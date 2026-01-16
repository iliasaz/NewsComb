import Foundation
#if os(macOS)
import AppKit
#endif

/// Service for exporting articles to Markdown files
enum MarkdownExportService {

    /// Convert an article to Markdown format
    static func articleToMarkdown(
        title: String,
        link: String,
        author: String?,
        pubDate: Date?,
        sourceName: String,
        content: String?
    ) -> String {
        var markdown = "# \(title)\n\n"

        // Metadata section
        markdown += "**Source:** \(sourceName)\n"
        if let author = author, !author.isEmpty {
            markdown += "**Author:** \(author)\n"
        }
        if let date = pubDate {
            let formatter = DateFormatter()
            formatter.dateStyle = .long
            formatter.timeStyle = .short
            markdown += "**Published:** \(formatter.string(from: date))\n"
        }
        markdown += "**Link:** \(link)\n"
        markdown += "\n---\n\n"

        // Content
        if let content = content, !content.isEmpty {
            // If content is HTML, strip tags for basic markdown
            if content.contains("</") {
                markdown += stripHTMLTags(content)
            } else {
                markdown += content
            }
        } else {
            markdown += "*No content available*"
        }

        return markdown
    }

    /// Strip HTML tags from content (basic conversion)
    private static func stripHTMLTags(_ html: String) -> String {
        var result = html

        // Convert common HTML to markdown
        result = result.replacingOccurrences(of: "<br>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<br/>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "<br />", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</p>", with: "\n\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</div>", with: "\n", options: .caseInsensitive)
        result = result.replacingOccurrences(of: "</li>", with: "\n", options: .caseInsensitive)

        // Strip remaining HTML tags
        result = result.replacingOccurrences(
            of: "<[^>]+>",
            with: "",
            options: .regularExpression
        )

        // Decode HTML entities
        result = result.replacingOccurrences(of: "&nbsp;", with: " ")
        result = result.replacingOccurrences(of: "&amp;", with: "&")
        result = result.replacingOccurrences(of: "&lt;", with: "<")
        result = result.replacingOccurrences(of: "&gt;", with: ">")
        result = result.replacingOccurrences(of: "&quot;", with: "\"")
        result = result.replacingOccurrences(of: "&#39;", with: "'")

        // Clean up extra whitespace
        result = result.replacingOccurrences(
            of: "\n{3,}",
            with: "\n\n",
            options: .regularExpression
        )

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Sanitize filename by removing invalid characters
    static func sanitizeFilename(_ name: String) -> String {
        var sanitized = name

        // Strip URL protocols if the name looks like a URL
        if sanitized.hasPrefix("https://") {
            sanitized = String(sanitized.dropFirst(8))
        } else if sanitized.hasPrefix("http://") {
            sanitized = String(sanitized.dropFirst(7))
        }

        // Remove common URL path components
        sanitized = sanitized
            .replacingOccurrences(of: "/feed", with: "")
            .replacingOccurrences(of: "/rss", with: "")
            .replacingOccurrences(of: ".xml", with: "")
            .replacingOccurrences(of: "/", with: "-")

        // Remove invalid filesystem characters
        let invalidCharacters = CharacterSet(charactersIn: ":/\\?%*|\"<>")
        sanitized = sanitized.components(separatedBy: invalidCharacters).joined(separator: "")

        // Clean up multiple dashes and trim
        while sanitized.contains("--") {
            sanitized = sanitized.replacingOccurrences(of: "--", with: "-")
        }
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: "- "))

        // Limit length
        if sanitized.count > 80 {
            sanitized = String(sanitized.prefix(80))
        }

        // Ensure not empty
        if sanitized.isEmpty {
            sanitized = "untitled"
        }

        return sanitized
    }

    /// Get current date string in YYYY-MM-DD format
    static func currentDateString() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date())
    }

    #if os(macOS)
    /// Show save panel for single file
    @MainActor
    static func showSavePanel(defaultName: String, fileExtension: String = "md") async -> URL? {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(sanitizeFilename(defaultName)).\(fileExtension)"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }

        if response == .OK {
            return panel.url
        }
        return nil
    }

    /// Show folder picker for export
    @MainActor
    static func showFolderPicker() async -> URL? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Select Folder"

        let response: NSApplication.ModalResponse
        if let window = NSApp.keyWindow {
            response = await panel.beginSheetModal(for: window)
        } else {
            response = await panel.begin()
        }

        if response == .OK {
            return panel.url
        }
        return nil
    }
    #endif

    /// Write markdown content to file
    static func writeToFile(content: String, at url: URL) throws {
        try content.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Create directory if it doesn't exist
    static func createDirectory(at url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }
}
