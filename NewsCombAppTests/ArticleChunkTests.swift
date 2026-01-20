import XCTest
@testable import NewsCombApp

final class ArticleChunkTests: XCTestCase {

    // MARK: - ArticleChunk Model Tests

    func testArticleChunkInitialization() {
        let date = Date(timeIntervalSince1970: 1000)
        let chunk = ArticleChunk(
            id: 1,
            feedItemId: 100,
            chunkIndex: 0,
            content: "This is a test chunk of text.",
            createdAt: date
        )

        XCTAssertEqual(chunk.id, 1)
        XCTAssertEqual(chunk.feedItemId, 100)
        XCTAssertEqual(chunk.chunkIndex, 0)
        XCTAssertEqual(chunk.content, "This is a test chunk of text.")
        XCTAssertEqual(chunk.createdAt, date)
    }

    func testArticleChunkInitializationWithDefaults() {
        let chunk = ArticleChunk(
            feedItemId: 100,
            chunkIndex: 0,
            content: "Test content"
        )

        XCTAssertNil(chunk.id)
        XCTAssertEqual(chunk.feedItemId, 100)
        XCTAssertEqual(chunk.chunkIndex, 0)
        XCTAssertEqual(chunk.content, "Test content")
        XCTAssertNotNil(chunk.createdAt)
    }

    func testArticleChunkTableName() {
        XCTAssertEqual(ArticleChunk.databaseTableName, "article_chunk")
    }

    func testArticleChunkEquatable() {
        let date = Date(timeIntervalSince1970: 1000)
        let chunk1 = ArticleChunk(
            id: 1,
            feedItemId: 100,
            chunkIndex: 0,
            content: "Test",
            createdAt: date
        )
        let chunk2 = ArticleChunk(
            id: 1,
            feedItemId: 100,
            chunkIndex: 0,
            content: "Test",
            createdAt: date
        )
        let chunk3 = ArticleChunk(
            id: 2,
            feedItemId: 100,
            chunkIndex: 1,
            content: "Different",
            createdAt: date
        )

        XCTAssertEqual(chunk1, chunk2)
        XCTAssertNotEqual(chunk1, chunk3)
    }

    func testArticleChunkIdentifiable() {
        let chunk = ArticleChunk(
            id: 42,
            feedItemId: 100,
            chunkIndex: 0,
            content: "Test"
        )

        XCTAssertEqual(chunk.id, 42)
    }

    // MARK: - ChunkEmbeddingMetadata Model Tests

    func testChunkEmbeddingMetadataInitialization() {
        let date = Date(timeIntervalSince1970: 2000)
        let metadata = ChunkEmbeddingMetadata(
            chunkId: 1,
            computedAt: date,
            modelName: "nomic-embed-text",
            embeddingVersion: 2
        )

        XCTAssertEqual(metadata.chunkId, 1)
        XCTAssertEqual(metadata.computedAt, date)
        XCTAssertEqual(metadata.modelName, "nomic-embed-text")
        XCTAssertEqual(metadata.embeddingVersion, 2)
    }

    func testChunkEmbeddingMetadataInitializationWithDefaults() {
        let metadata = ChunkEmbeddingMetadata(chunkId: 1)

        XCTAssertEqual(metadata.chunkId, 1)
        XCTAssertNotNil(metadata.computedAt)
        XCTAssertNil(metadata.modelName)
        XCTAssertEqual(metadata.embeddingVersion, 1)
    }

    func testChunkEmbeddingMetadataTableName() {
        XCTAssertEqual(ChunkEmbeddingMetadata.databaseTableName, "chunk_embedding_metadata")
    }

    func testChunkEmbeddingMetadataIdentifiable() {
        let metadata = ChunkEmbeddingMetadata(chunkId: 42)

        XCTAssertEqual(metadata.id, 42)
    }

    func testChunkEmbeddingMetadataEquatable() {
        let date = Date(timeIntervalSince1970: 1000)
        let meta1 = ChunkEmbeddingMetadata(
            chunkId: 1,
            computedAt: date,
            modelName: "model",
            embeddingVersion: 1
        )
        let meta2 = ChunkEmbeddingMetadata(
            chunkId: 1,
            computedAt: date,
            modelName: "model",
            embeddingVersion: 1
        )
        let meta3 = ChunkEmbeddingMetadata(
            chunkId: 2,
            computedAt: date,
            modelName: "different",
            embeddingVersion: 2
        )

        XCTAssertEqual(meta1, meta2)
        XCTAssertNotEqual(meta1, meta3)
    }

    // MARK: - Column Expression Tests

    func testArticleChunkColumnExpressions() {
        XCTAssertEqual(ArticleChunk.Columns.id.rawValue, "id")
        XCTAssertEqual(ArticleChunk.Columns.feedItemId.rawValue, "feed_item_id")
        XCTAssertEqual(ArticleChunk.Columns.chunkIndex.rawValue, "chunk_index")
        XCTAssertEqual(ArticleChunk.Columns.content.rawValue, "content")
        XCTAssertEqual(ArticleChunk.Columns.createdAt.rawValue, "created_at")
    }

    func testChunkEmbeddingMetadataColumnExpressions() {
        XCTAssertEqual(ChunkEmbeddingMetadata.Columns.chunkId.rawValue, "chunk_id")
        XCTAssertEqual(ChunkEmbeddingMetadata.Columns.computedAt.rawValue, "computed_at")
        XCTAssertEqual(ChunkEmbeddingMetadata.Columns.modelName.rawValue, "model_name")
        XCTAssertEqual(ChunkEmbeddingMetadata.Columns.embeddingVersion.rawValue, "embedding_version")
    }
}
