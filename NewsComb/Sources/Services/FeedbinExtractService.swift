import Foundation
import CryptoKit
import GRDB

struct ExtractedContent: Decodable {
    let title: String?
    let author: String?
    let datePublished: String?
    let content: String?
    let url: String?
    let domain: String?
    let excerpt: String?
    let leadImageUrl: String?

    enum CodingKeys: String, CodingKey {
        case title, author, content, url, domain, excerpt
        case datePublished = "date_published"
        case leadImageUrl = "lead_image_url"
    }
}

struct FeedbinExtractService {
    private let database = Database.shared
    private let baseURL = "https://extract.feedbin.com/parser"

    @concurrent
    func extractContent(from articleURL: String) async throws -> String? {
        let credentials = try getCredentials()

        guard let username = credentials.username, let secret = credentials.secret,
              !username.isEmpty, !secret.isEmpty else {
            return nil
        }

        let signature = generateSignature(url: articleURL, secret: secret)
        let encodedURL = base64URLEncode(articleURL)

        guard let requestURL = URL(string: "\(baseURL)/\(username)/\(signature)?base64_url=\(encodedURL)") else {
            throw URLError(.badURL)
        }

        let (data, response) = try await URLSession.shared.data(from: requestURL)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw URLError(.badServerResponse)
        }

        let extracted = try JSONDecoder().decode(ExtractedContent.self, from: data)
        return extracted.content
    }

    private func getCredentials() throws -> (username: String?, secret: String?) {
        var username: String?
        var secret: String?

        try database.read { db in
            if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.feedbinUsername).fetchOne(db) {
                username = setting.value
            }
            if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.feedbinSecret).fetchOne(db) {
                secret = setting.value
            }
        }

        return (username, secret)
    }

    private func generateSignature(url: String, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let signature = HMAC<Insecure.SHA1>.authenticationCode(
            for: Data(url.utf8),
            using: key
        )
        return signature.map { String(format: "%02x", $0) }.joined()
    }

    private func base64URLEncode(_ url: String) -> String {
        Data(url.utf8).base64EncodedString()
            .replacing("+", with: "-")
            .replacing("/", with: "_")
            .replacing("=", with: "")
    }

    // MARK: - Testable methods

    func testableGenerateSignature(url: String, secret: String) -> String {
        generateSignature(url: url, secret: secret)
    }

    func testableBase64URLEncode(_ url: String) -> String {
        base64URLEncode(url)
    }
}
