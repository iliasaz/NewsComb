import Foundation

/// Utility for sanitizing and fixing malformed URLs
enum URLSanitizer {
    /// Sanitize a URL to fix common malformations
    /// - Ensures path starts with / after domain
    /// - Trims whitespace
    /// - Returns nil if URL is fundamentally invalid
    static func sanitize(_ urlString: String) -> String? {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Try to parse as URL first
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            // URL is valid, but check if path is malformed (missing leading /)
            var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
            if let path = components?.path, !path.isEmpty, !path.hasPrefix("/") {
                components?.path = "/" + path
                return components?.string
            }
            return trimmed
        }

        // Try to fix common malformations
        // Pattern: https://domain.compath -> https://domain.com/path
        if let schemeRange = trimmed.range(of: "://") {
            let afterScheme = trimmed[schemeRange.upperBound...]

            // Find where the domain ends (first / or end of string)
            if let slashIndex = afterScheme.firstIndex(of: "/") {
                // Has a slash, URL might be fine or might have issues
                let domain = String(afterScheme[..<slashIndex])
                let path = String(afterScheme[slashIndex...])

                // Reconstruct URL
                let scheme = String(trimmed[..<schemeRange.upperBound])
                let reconstructed = scheme + domain + path

                if URL(string: reconstructed) != nil {
                    return reconstructed
                }
            } else {
                // No slash at all - check if domain contains path-like content
                // e.g., "amazon.comabout-aws" should become "amazon.com/about-aws"
                let domainPart = String(afterScheme)

                // Common TLDs to look for
                let tlds = [".com", ".org", ".net", ".edu", ".gov", ".io", ".co", ".dev", ".info", ".biz", ".us", ".uk", ".ca", ".au"]

                for tld in tlds {
                    if let tldRange = domainPart.range(of: tld, options: .caseInsensitive) {
                        let afterTld = domainPart[tldRange.upperBound...]
                        if !afterTld.isEmpty && !afterTld.hasPrefix("/") && !afterTld.hasPrefix(":") {
                            // Found path-like content after TLD without slash
                            let domain = String(domainPart[..<tldRange.upperBound])
                            let path = "/" + String(afterTld)
                            let scheme = String(trimmed[..<schemeRange.upperBound])
                            let fixed = scheme + domain + path

                            if URL(string: fixed) != nil {
                                return fixed
                            }
                        }
                        break
                    }
                }
            }
        }

        // Return original if we couldn't fix it
        return URL(string: trimmed) != nil ? trimmed : nil
    }
}
