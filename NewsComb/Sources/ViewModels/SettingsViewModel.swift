import Foundation
import Observation
import GRDB

@Observable
class SettingsViewModel {
    var rssSources: [RSSSource] = []
    var newSourceURL: String = ""
    var feedbinUsername: String = ""
    var feedbinSecret: String = ""
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
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.feedbinUsername).fetchOne(db) {
                    feedbinUsername = setting.value
                }
                if let setting = try AppSettings.filter(AppSettings.Columns.key == AppSettings.feedbinSecret).fetchOne(db) {
                    feedbinSecret = setting.value
                }
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
        do {
            _ = try database.write { db in
                try RSSSource(url: url).insert(db, onConflict: .ignore)
            }
            loadRSSSources()
        } catch {
            errorMessage = "Failed to add source: \(error.localizedDescription)"
        }
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

    func saveFeedbinUsername() {
        saveAPIKey(key: AppSettings.feedbinUsername, value: feedbinUsername)
    }

    func saveFeedbinSecret() {
        saveAPIKey(key: AppSettings.feedbinSecret, value: feedbinSecret)
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
