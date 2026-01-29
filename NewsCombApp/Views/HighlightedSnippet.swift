import SwiftUI

/// Renders an FTS5 snippet string (with `<b>` markers) as highlighted `Text`.
///
/// FTS5's `snippet()` function wraps matched terms in `<b>...</b>` tags.
/// This view converts those tags into an `AttributedString` with yellow
/// background highlighting and bold weight on matched ranges.
struct HighlightedSnippet: View {
    let snippet: String

    var body: some View {
        Text(highlightedText)
    }

    private var highlightedText: AttributedString {
        var result = AttributedString()
        var remaining = snippet[...]

        while let openRange = remaining.range(of: "<b>") {
            // Append text before the <b> tag
            let before = remaining[remaining.startIndex..<openRange.lowerBound]
            result.append(AttributedString(before))

            remaining = remaining[openRange.upperBound...]

            // Find the closing </b>
            if let closeRange = remaining.range(of: "</b>") {
                let matched = remaining[remaining.startIndex..<closeRange.lowerBound]
                var highlighted = AttributedString(matched)
                highlighted.backgroundColor = .yellow.opacity(0.3)
                highlighted.inlinePresentationIntent = .stronglyEmphasized
                result.append(highlighted)
                remaining = remaining[closeRange.upperBound...]
            } else {
                // No closing tag — append the rest as-is
                result.append(AttributedString(remaining))
                remaining = remaining[remaining.endIndex...]
            }
        }

        // Append any trailing text
        if !remaining.isEmpty {
            result.append(AttributedString(remaining))
        }

        return result
    }
}

// MARK: - Query-Based Text Highlighting

/// Highlights occurrences of search terms within plain text.
///
/// Unlike `HighlightedSnippet` (which parses FTS5 `<b>` markers), this
/// builds an `AttributedString` by splitting on query words and applying
/// yellow background highlighting to every match.
struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(highlightedAttributedString)
    }

    private var highlightedAttributedString: AttributedString {
        let words = query
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: " ", omittingEmptySubsequences: true)
            .map { String($0) }

        guard !words.isEmpty else {
            return AttributedString(text)
        }

        var result = AttributedString(text)

        for word in words {
            guard !word.isEmpty else { continue }

            // Walk through the attributed string and highlight matches
            var searchStart = result.startIndex
            while searchStart < result.endIndex {
                let remainingRange = searchStart..<result.endIndex
                let plain = String(result[remainingRange].characters)

                guard let matchRange = plain.range(of: word, options: [.caseInsensitive, .diacriticInsensitive]) else {
                    break
                }

                // Convert String range to AttributedString range
                let matchDistance = plain.distance(from: plain.startIndex, to: matchRange.lowerBound)
                let matchLength = plain.distance(from: matchRange.lowerBound, to: matchRange.upperBound)

                let attrStart = result.index(searchStart, offsetByCharacters: matchDistance)
                let attrEnd = result.index(attrStart, offsetByCharacters: matchLength)
                let attrRange = attrStart..<attrEnd

                result[attrRange].backgroundColor = .yellow.opacity(0.3)
                result[attrRange].inlinePresentationIntent = .stronglyEmphasized

                searchStart = attrEnd
            }
        }

        return result
    }
}
