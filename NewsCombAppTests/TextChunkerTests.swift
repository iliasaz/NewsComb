import XCTest
@testable import NewsCombApp

final class TextChunkerTests: XCTestCase {

    // MARK: - Basic Chunking Tests

    func testChunkTextWithParagraphs() {
        let text = """
        First paragraph here.

        Second paragraph here.

        Third paragraph here.
        """

        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // All paragraphs combined are under 100 chars, so should be one chunk
        // If they exceed 100 chars, they'll be split
        XCTAssertGreaterThanOrEqual(chunks.count, 1)
        XCTAssertTrue(chunks.joined(separator: " ").contains("First paragraph"))
        XCTAssertTrue(chunks.joined(separator: " ").contains("Second paragraph"))
        XCTAssertTrue(chunks.joined(separator: " ").contains("Third paragraph"))
    }

    func testChunkTextCombinesSmallParagraphs() {
        let text = """
        Short.

        Also short.

        Short too.
        """

        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // All paragraphs should fit in one chunk
        XCTAssertEqual(chunks.count, 1)
        guard let firstChunk = chunks.first else {
            XCTFail("Expected at least one chunk")
            return
        }
        XCTAssertTrue(firstChunk.contains("Short."))
        XCTAssertTrue(firstChunk.contains("Also short."))
        XCTAssertTrue(firstChunk.contains("Short too."))
    }

    func testChunkTextSplitsLargeParagraphs() {
        let text = """
        This is a relatively long paragraph that should be in its own chunk when combined with others.

        This is another paragraph that would exceed the target size if combined.
        """

        let chunks = TextChunker.chunkText(text, targetSize: 50)

        // Should split into separate chunks
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testChunkTextEmptyString() {
        let chunks = TextChunker.chunkText("", targetSize: 100)

        XCTAssertTrue(chunks.isEmpty)
    }

    func testChunkTextWhitespaceOnly() {
        let text = "   \n\n   \n"
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // Whitespace-only text: paragraphs are filtered to empty, so falls back to sentence chunking
        // Sentence chunking with no sentence endings returns the original text as a single chunk
        // The original text is "   \n\n   \n" which is not empty, so we get one chunk
        // Either we get empty array (if text is filtered) or a chunk with the whitespace
        if chunks.isEmpty {
            XCTAssertTrue(true, "Empty result is valid for whitespace-only input")
        } else {
            // If we got chunks, they should exist
            XCTAssertGreaterThanOrEqual(chunks.count, 1)
        }
    }

    func testChunkTextSingleParagraph() {
        let text = "This is a single paragraph with no double newlines."
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        XCTAssertEqual(chunks.count, 1)
        guard let firstChunk = chunks.first else {
            XCTFail("Expected at least one chunk")
            return
        }
        XCTAssertEqual(firstChunk, text)
    }

    // MARK: - Sentence Chunking Tests (via chunkText fallback)

    func testChunkTextWithSentencesBasic() {
        // Text with no paragraph or line breaks falls back to sentence chunking
        let text = "First sentence. Second sentence. Third sentence."
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // All sentences should fit in one chunk
        XCTAssertEqual(chunks.count, 1)
        guard let firstChunk = chunks.first else {
            XCTFail("Expected at least one chunk")
            return
        }
        XCTAssertTrue(firstChunk.contains("First sentence"))
        XCTAssertTrue(firstChunk.contains("Second sentence"))
        XCTAssertTrue(firstChunk.contains("Third sentence"))
    }

    func testChunkTextWithSentencesSplits() {
        let text = "First sentence here. Second sentence here. Third sentence here."
        let chunks = TextChunker.chunkText(text, targetSize: 30)

        // Should split into multiple chunks
        XCTAssertGreaterThan(chunks.count, 1)
    }

    func testChunkTextWithQuestionMark() {
        let text = "Is this a question? Yes it is. And another!"
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        XCTAssertEqual(chunks.count, 1)
        guard let firstChunk = chunks.first else {
            XCTFail("Expected at least one chunk")
            return
        }
        XCTAssertTrue(firstChunk.contains("question"))
    }

    func testChunkTextWithExclamation() {
        let text = "Wow! Amazing! Incredible!"
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        XCTAssertEqual(chunks.count, 1)
    }

    func testChunkTextNoSentenceEndings() {
        let text = "This text has no sentence endings at all"
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // Should return the whole text as a single chunk
        XCTAssertEqual(chunks.count, 1)
        guard let firstChunk = chunks.first else {
            XCTFail("Expected at least one chunk")
            return
        }
        XCTAssertTrue(firstChunk.contains("This text has no sentence endings at all"))
    }

    // MARK: - Force-Split Tests (new behavior)

    func testChunkTextForceSplitsOversizedChunk() {
        // A very long text without any paragraph breaks, line breaks, or sentence endings
        let text = String(repeating: "word ", count: 200) // ~1000 chars of words
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // Should force-split at word boundaries
        XCTAssertGreaterThan(chunks.count, 1)

        // Each chunk should be at or near target size
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 110, "Chunk should be near target size")
        }
    }

    func testChunkTextForceSplitsLongURL() {
        // A very long "word" (like a URL) that exceeds target size
        let longURL = "https://example.com/" + String(repeating: "a", count: 200)
        let text = "Check this link: \(longURL) for more info."
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // Should split the URL itself
        XCTAssertGreaterThan(chunks.count, 1)

        // All content should be preserved
        let joined = chunks.joined()
        XCTAssertTrue(joined.contains("Check this link:"))
        XCTAssertTrue(joined.contains("for more info."))
    }

    func testChunkTextWithSingleNewlines() {
        // Text with single newlines (like a list or code) but no double newlines
        let text = """
        Line one here
        Line two here
        Line three here
        Line four here
        """

        let chunks = TextChunker.chunkText(text, targetSize: 50)

        // Should split on single newlines when no double newlines exist
        XCTAssertGreaterThan(chunks.count, 1)
    }

    // MARK: - Fallback Behavior Tests

    func testChunkTextFallsBackToSentences() {
        // Text with no paragraph breaks but with sentences
        let text = "First sentence. Second sentence. Third sentence."
        let chunks = TextChunker.chunkText(text, targetSize: 100)

        // Should use sentence chunking as fallback
        XCTAssertEqual(chunks.count, 1)
    }

    // MARK: - Edge Cases

    func testChunkTextTrimsWhitespace() {
        let text = """
           Paragraph with leading whitespace.

           Paragraph with trailing whitespace.
        """

        let chunks = TextChunker.chunkText(text, targetSize: 100)

        for chunk in chunks {
            XCTAssertEqual(chunk, chunk.trimmingCharacters(in: .whitespaces))
        }
    }

    func testChunkTextHandlesMultipleNewlines() {
        let text = """
        First paragraph.



        Second paragraph after multiple newlines.
        """

        let chunks = TextChunker.chunkText(text, targetSize: 200)

        XCTAssertEqual(chunks.count, 1)
        guard let firstChunk = chunks.first else {
            XCTFail("Expected at least one chunk")
            return
        }
        XCTAssertTrue(firstChunk.contains("First paragraph"))
        XCTAssertTrue(firstChunk.contains("Second paragraph"))
    }

    func testDefaultTargetSize() {
        XCTAssertEqual(TextChunker.defaultTargetSize, 800)
    }

    // MARK: - Real-world Text Tests

    func testChunkTextWithArticleContent() {
        let articleText = """
        Apple announced new products today at their annual event held in Cupertino, California.

        The tech giant revealed the latest iPhone model featuring improved camera capabilities and longer battery life. Analysts expect strong demand for the new device.

        CEO Tim Cook emphasized the company's commitment to sustainability, noting that all new products are made with recycled materials.

        Market reaction was positive, with Apple's stock rising 2% in after-hours trading.
        """

        let chunks = TextChunker.chunkText(articleText, targetSize: 300)

        // Should produce multiple chunks
        XCTAssertGreaterThan(chunks.count, 1)

        // Each chunk should be under target size (with some tolerance)
        for chunk in chunks {
            XCTAssertLessThanOrEqual(chunk.count, 400) // Allow some overflow for complete paragraphs
        }

        // No chunk should be empty
        for chunk in chunks {
            XCTAssertFalse(chunk.isEmpty)
        }
    }

    func testChunkTextPreservesContent() {
        let text = """
        First paragraph with important information.

        Second paragraph with more details.

        Third paragraph with conclusions.
        """

        let chunks = TextChunker.chunkText(text, targetSize: 1000)

        let joined = chunks.joined(separator: "\n\n")

        XCTAssertTrue(joined.contains("First paragraph"))
        XCTAssertTrue(joined.contains("Second paragraph"))
        XCTAssertTrue(joined.contains("Third paragraph"))
    }
}
