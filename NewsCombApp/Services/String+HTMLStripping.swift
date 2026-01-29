import Foundation

extension String {
    /// Strips HTML tags and decodes common HTML entities from the string.
    /// Used to clean provenance text that may contain raw HTML from RSS feeds.
    func strippingHTMLTags() -> String {
        // Remove HTML tags using regex
        var result = self
        if let tagRegex = try? Regex("<[^>]+>") {
            result = result.replacing(tagRegex, with: "")
        }

        // Decode common HTML entities
        let entities: [(entity: String, replacement: String)] = [
            ("&amp;", "&"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&nbsp;", " "),
        ]
        for (entity, replacement) in entities {
            result = result.replacing(entity, with: replacement)
        }

        // Collapse multiple whitespace/newlines into single spaces
        if let whitespaceRegex = try? Regex(#"\s+"#) {
            result = result.replacing(whitespaceRegex, with: " ")
        }

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
