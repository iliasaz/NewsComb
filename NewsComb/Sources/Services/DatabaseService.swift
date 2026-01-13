import Foundation
import GRDB

public final class Database: Sendable {
    public static let shared = Database()

    let dbQueue: DatabaseQueue

    private init() {
        do {
            let fileManager = FileManager.default
            let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            let dbDirectory = appSupport.appending(path: "NewsComb")

            try fileManager.createDirectory(at: dbDirectory, withIntermediateDirectories: true)

            let dbPath = dbDirectory.appending(path: "newscomb.sqlite")
            dbQueue = try DatabaseQueue(path: dbPath.path)

            try migrate()
        } catch {
            fatalError("Failed to initialize database: \(error)")
        }
    }

    private func migrate() throws {
        try dbQueue.write { db in
            try db.execute(sql: """
                CREATE TABLE IF NOT EXISTS rss_source (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    url TEXT NOT NULL UNIQUE,
                    title TEXT,
                    created_at REAL NOT NULL DEFAULT (unixepoch())
                );

                CREATE TABLE IF NOT EXISTS feed_item (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    source_id INTEGER NOT NULL REFERENCES rss_source(id) ON DELETE CASCADE,
                    guid TEXT NOT NULL,
                    title TEXT NOT NULL,
                    link TEXT NOT NULL,
                    pub_date REAL,
                    rss_description TEXT,
                    full_content TEXT,
                    author TEXT,
                    fetched_at REAL NOT NULL DEFAULT (unixepoch()),
                    UNIQUE(source_id, guid)
                );

                CREATE TABLE IF NOT EXISTS app_settings (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    key TEXT NOT NULL UNIQUE,
                    value TEXT NOT NULL
                );

                CREATE INDEX IF NOT EXISTS idx_feed_item_source ON feed_item(source_id);
                CREATE INDEX IF NOT EXISTS idx_feed_item_guid ON feed_item(guid);
            """)
        }
    }

    func read<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }

    func write<T>(_ block: (GRDB.Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
}
