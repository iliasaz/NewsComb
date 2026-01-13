import Testing
import Foundation
@testable import NewsComb

struct FeedbinExtractServiceTests {
    @Test
    func signatureGeneration() {
        let service = FeedbinExtractService()

        let url = "https://example.com/article"
        let secret = "test_secret"

        let signature = service.testableGenerateSignature(url: url, secret: secret)
        #expect(!signature.isEmpty)
        #expect(signature.count == 40)
    }

    @Test
    func base64URLEncoding() {
        let service = FeedbinExtractService()

        let url = "https://example.com/article?param=value"
        let encoded = service.testableBase64URLEncode(url)

        #expect(!encoded.contains("+"))
        #expect(!encoded.contains("/"))
        #expect(!encoded.contains("="))
    }
}
