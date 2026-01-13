import Foundation
import Observation
import GRDB

@MainActor
@Observable
class SettingsViewModel {
    var rssSources: [RSSSource] = []
    var newSourceURL: String = ""
    var openRouterKey: String = ""
    var errorMessage: String?

    private let database = Database.shared

    func loadData() {
        loadRSSSources()
        loadAPIKeys()
    }

    private func loadRSSSources() {
        do {
            rssSources = try database.read { db in
                try RSSSource.fetchAll(db)
            }
        } catch {
            errorMessage = "Failed to load RSS sources: \(error.localizedDescription)"
        }
    }

    private func loadAPIKeys() {
        do {
            try database.read { db in
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.openRouterKey).fetchOne(db) {
                    openRouterKey = setting.value
                }
            }
        } catch {
            errorMessage = "Failed to load API keys: \(error.localizedDescription)"
        }
    }

    func addSource() {
        let trimmed = newSourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        addSourceURL(trimmed)
        newSourceURL = ""
    }

    func pasteMultipleSources(_ text: String) {
        let urls = text.components(separatedBy: CharacterSet.newlines)
            .flatMap { $0.components(separatedBy: ",") }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.hasPrefix("http") }

        for url in urls {
            addSourceURL(url)
        }
    }

    private func addSourceURL(_ url: String) {
        let normalizedURL = normalizeURL(url)

        // Check if URL already exists (normalized comparison)
        let existingURLs = rssSources.map { normalizeURL($0.url) }
        if existingURLs.contains(normalizedURL) {
            errorMessage = "This feed URL already exists in your sources."
            return
        }

        do {
            _ = try database.write { db in
                try RSSSource(url: normalizedURL).insert(db, onConflict: .ignore)
            }
            loadRSSSources()
        } catch {
            errorMessage = "Failed to add source: \(error.localizedDescription)"
        }
    }

    /// Normalize URL for consistent comparison
    /// - Removes trailing slashes
    /// - Lowercases the scheme and host
    /// - Removes default ports (80 for http, 443 for https)
    private func normalizeURL(_ urlString: String) -> String {
        guard var components = URLComponents(string: urlString) else {
            return urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Lowercase scheme and host
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()

        // Remove default ports
        if let port = components.port {
            if (components.scheme == "http" && port == 80) ||
               (components.scheme == "https" && port == 443) {
                components.port = nil
            }
        }

        // Remove trailing slash from path
        if components.path.hasSuffix("/") && components.path.count > 1 {
            components.path = String(components.path.dropLast())
        }

        return components.string ?? urlString.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func deleteSource(_ source: RSSSource) {
        do {
            _ = try database.write { db in
                try source.delete(db)
            }
            loadRSSSources()
        } catch {
            errorMessage = "Failed to delete source: \(error.localizedDescription)"
        }
    }

    func deleteSource(at offsets: IndexSet) {
        for index in offsets {
            deleteSource(rssSources[index])
        }
    }

    func saveOpenRouterKey() {
        saveAPIKey(key: AppSettings.openRouterKey, value: openRouterKey)
    }

    private func saveAPIKey(key: String, value: String) {
        do {
            try database.write { db in
                try db.execute(
                    sql: """
                        INSERT INTO app_settings (key, value) VALUES (?, ?)
                        ON CONFLICT(key) DO UPDATE SET value = excluded.value
                    """,
                    arguments: [key, value]
                )
            }
        } catch {
            errorMessage = "Failed to save API key: \(error.localizedDescription)"
        }
    }
}
