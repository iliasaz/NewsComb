import Foundation
import OPML
import OSLog

/// Represents a single feed extracted from an OPML document.
struct OPMLFeed: Equatable {
    let xmlUrl: String
    let title: String?
    let htmlUrl: String?
}

/// Result of an OPML import operation.
struct OPMLImportResult: Equatable {
    let added: Int
    let skipped: Int
    let total: Int
}

/// Service for importing RSS feeds from OPML files and URLs.
struct OPMLImportService {
    private static let logger = Logger(subsystem: "com.newscomb.app", category: "opml-import")

    /// Parse feeds from local OPML file data.
    func parseFeeds(from data: Data) throws -> [OPMLFeed] {
        let opml = try OPMLParser.parse(data: data)
        var feeds: [OPMLFeed] = []
        collectFeeds(from: opml.outlines, into: &feeds)
        return deduplicateFeeds(feeds)
    }

    /// Parse feeds from a local OPML file URL.
    func parseFeeds(fromFile url: URL) throws -> [OPMLFeed] {
        let data = try Data(contentsOf: url)
        return try parseFeeds(from: data)
    }

    /// Download and parse feeds from a remote OPML URL.
    @concurrent
    func parseFeeds(fromRemoteURL url: URL) async throws -> [OPMLFeed] {
        Self.logger.info("Fetching OPML from remote URL: \(url.absoluteString)")
        let (data, response) = try await URLSession.shared.data(from: url)

        if let httpResponse = response as? HTTPURLResponse,
           !(200...299).contains(httpResponse.statusCode) {
            throw OPMLImportError.httpError(statusCode: httpResponse.statusCode)
        }

        return try parseFeeds(from: data)
    }

    // MARK: - Private

    /// Recursively walk the outline tree and collect all outlines that have a feed URL.
    private func collectFeeds(from outlines: [OPML.Outline], into feeds: inout [OPMLFeed]) {
        for outline in outlines {
            if let feedURL = outline.feedURL {
                feeds.append(OPMLFeed(
                    xmlUrl: feedURL.absoluteString,
                    title: outline.title.isEmpty ? nil : outline.title,
                    htmlUrl: outline.siteURL?.absoluteString
                ))
            }

            // Recurse into children (category groups)
            if let children = outline.children {
                collectFeeds(from: children, into: &feeds)
            }
        }
    }

    /// Remove duplicate feed URLs (keep first occurrence).
    private func deduplicateFeeds(_ feeds: [OPMLFeed]) -> [OPMLFeed] {
        var seenURLs: Set<String> = []
        return feeds.filter { feed in
            let normalized = feed.xmlUrl.lowercased()
            if seenURLs.contains(normalized) {
                return false
            }
            seenURLs.insert(normalized)
            return true
        }
    }
}

enum OPMLImportError: LocalizedError {
    case httpError(statusCode: Int)
    case noFeedsFound

    var errorDescription: String? {
        switch self {
        case .httpError(let statusCode):
            "Failed to download OPML file (HTTP \(statusCode))"
        case .noFeedsFound:
            "No RSS feeds found in the OPML file"
        }
    }
}
