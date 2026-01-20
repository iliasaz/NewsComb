import Foundation

/// Utility for chunking text into smaller segments for processing.
enum TextChunker {

    /// Default target chunk size in characters.
    static let defaultTargetSize = 800

    /// Chunks text into paragraphs for provenance tracking.
    /// Aims for chunks of roughly 500-1000 characters to balance granularity and context.
    /// - Parameters:
    ///   - text: The text to chunk
    ///   - targetSize: Target maximum size for each chunk
    /// - Returns: Array of text chunks
    static func chunkText(_ text: String, targetSize: Int = defaultTargetSize) -> [String] {
        // Split by double newlines (paragraphs)
        let paragraphs = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !paragraphs.isEmpty else {
            // Fallback: split by sentences if no paragraphs
            return chunkBySentences(text, targetSize: targetSize)
        }

        var chunks: [String] = []
        var currentChunk = ""

        for paragraph in paragraphs {
            if currentChunk.isEmpty {
                currentChunk = paragraph
            } else if currentChunk.count + paragraph.count + 2 <= targetSize {
                // Add to current chunk if within target size
                currentChunk += "\n\n" + paragraph
            } else {
                // Start a new chunk
                chunks.append(currentChunk)
                currentChunk = paragraph
            }
        }

        // Don't forget the last chunk
        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }

    /// Fallback chunking by sentences when paragraphs aren't available.
    /// - Parameters:
    ///   - text: The text to chunk
    ///   - targetSize: Target maximum size for each chunk
    /// - Returns: Array of text chunks
    static func chunkBySentences(_ text: String, targetSize: Int) -> [String] {
        let sentences = text.components(separatedBy: CharacterSet(charactersIn: ".!?"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !sentences.isEmpty else {
            // Last resort: return the whole text as a single chunk
            return text.isEmpty ? [] : [text]
        }

        var chunks: [String] = []
        var currentChunk = ""

        for sentence in sentences {
            let sentenceWithPunct = sentence + "."
            if currentChunk.isEmpty {
                currentChunk = sentenceWithPunct
            } else if currentChunk.count + sentenceWithPunct.count + 1 <= targetSize {
                currentChunk += " " + sentenceWithPunct
            } else {
                chunks.append(currentChunk)
                currentChunk = sentenceWithPunct
            }
        }

        if !currentChunk.isEmpty {
            chunks.append(currentChunk)
        }

        return chunks
    }
}
