import Foundation

/// Utility for chunking text into smaller segments for processing.
enum TextChunker {

    /// Default target chunk size in characters.
    static let defaultTargetSize = 800

    /// Chunks text into paragraphs for provenance tracking.
    /// Aims for chunks of roughly 500-1000 characters to balance granularity and context.
    ///
    /// Uses a cascading fallback strategy:
    /// 1. Split by double newlines (`\n\n`) for paragraph-structured text
    /// 2. Split by single newlines (`\n`) for line-structured text (e.g., lists, code)
    /// 3. Split by sentences for prose without line breaks
    /// 4. Force-split any remaining oversized chunks at word boundaries
    ///
    /// - Parameters:
    ///   - text: The text to chunk
    ///   - targetSize: Target maximum size for each chunk
    /// - Returns: Array of text chunks
    static func chunkText(_ text: String, targetSize: Int = defaultTargetSize) -> [String] {
        guard !text.isEmpty else { return [] }

        // Strategy 1: Split by double newlines (paragraphs)
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        // Check if we got meaningful paragraph splits (more than 1 segment)
        if paragraphs.count > 1 {
            let chunks = mergeSegments(paragraphs, separator: "\n\n", targetSize: targetSize)
            return forceSplitOversizedChunks(chunks, targetSize: targetSize)
        }

        // Strategy 2: Fall back to single newlines
        let lines = text
            .components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        if lines.count > 1 {
            let chunks = mergeSegments(lines, separator: "\n", targetSize: targetSize)
            return forceSplitOversizedChunks(chunks, targetSize: targetSize)
        }

        // Strategy 3: Fall back to sentences
        let sentenceChunks = chunkBySentences(text, targetSize: targetSize)
        return forceSplitOversizedChunks(sentenceChunks, targetSize: targetSize)
    }

    /// Merges segments into chunks up to targetSize, preserving natural boundaries.
    private static func mergeSegments(_ segments: [String], separator: String, targetSize: Int) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""

        for segment in segments {
            if currentChunk.isEmpty {
                currentChunk = segment
            } else if currentChunk.count + segment.count + separator.count <= targetSize {
                currentChunk += separator + segment
            } else {
                chunks.append(currentChunk)
                currentChunk = segment
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    /// Force-splits any chunks that exceed targetSize at word boundaries.
    private static func forceSplitOversizedChunks(_ chunks: [String], targetSize: Int) -> [String] {
        var result: [String] = []

        for chunk in chunks {
            if chunk.count <= targetSize {
                result.append(chunk)
            } else {
                // Split at word boundaries
                result.append(contentsOf: splitAtWordBoundaries(chunk, targetSize: targetSize))
            }
        }

        return result
    }

    /// Splits text at word boundaries to stay within targetSize.
    private static func splitAtWordBoundaries(_ text: String, targetSize: Int) -> [String] {
        var chunks: [String] = []
        var currentChunk = ""

        let words = text.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        for word in words {
            if currentChunk.isEmpty {
                // Handle extremely long words (e.g., URLs)
                if word.count > targetSize {
                    chunks.append(contentsOf: splitLongWord(word, targetSize: targetSize))
                } else {
                    currentChunk = word
                }
            } else if currentChunk.count + word.count + 1 <= targetSize {
                currentChunk += " " + word
            } else {
                chunks.append(currentChunk)
                if word.count > targetSize {
                    chunks.append(contentsOf: splitLongWord(word, targetSize: targetSize))
                    currentChunk = ""
                } else {
                    currentChunk = word
                }
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    /// Splits a word that exceeds targetSize (e.g., long URLs).
    private static func splitLongWord(_ word: String, targetSize: Int) -> [String] {
        var chunks: [String] = []
        var startIndex = word.startIndex

        while startIndex < word.endIndex {
            let endIndex = word.index(startIndex, offsetBy: targetSize, limitedBy: word.endIndex) ?? word.endIndex
            chunks.append(String(word[startIndex..<endIndex]))
            startIndex = endIndex
        }

        return chunks
    }

    /// Fallback chunking by sentences when paragraphs/lines aren't available.
    /// - Parameters:
    ///   - text: The text to chunk
    ///   - targetSize: Target maximum size for each chunk
    /// - Returns: Array of text chunks
    private static func chunkBySentences(_ text: String, targetSize: Int) -> [String] {
        // Use a regex-based approach to preserve sentence-ending punctuation
        let pattern = #"[^.!?]+[.!?]+"#
        let regex = try? NSRegularExpression(pattern: pattern, options: [])
        let range = NSRange(text.startIndex..., in: text)

        var sentences: [String] = []
        regex?.enumerateMatches(in: text, options: [], range: range) { match, _, _ in
            if let matchRange = match?.range, let swiftRange = Range(matchRange, in: text) {
                let sentence = String(text[swiftRange]).trimmingCharacters(in: .whitespaces)
                if !sentence.isEmpty {
                    sentences.append(sentence)
                }
            }
        }

        // If regex found no sentences, the text has no sentence-ending punctuation
        // Return the whole text (it will be force-split later)
        guard !sentences.isEmpty else {
            return text.isEmpty ? [] : [text.trimmingCharacters(in: .whitespacesAndNewlines)]
        }

        return mergeSegments(sentences, separator: " ", targetSize: targetSize)
    }
}
