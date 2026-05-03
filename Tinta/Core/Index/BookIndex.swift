import Foundation
import GRDB
import os

private nonisolated let logger = Logger(subsystem: "com.pdrbrnd.tinta", category: "index")

actor BookIndex {
    private let pool: DatabasePool

    init() throws {
        let url = try Self.databaseURL()
        logger.info("opening index at \(url.path(percentEncoded: false), privacy: .public)")
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        try Self.migrator.migrate(pool)
        self.pool = pool
    }

    static func open() -> BookIndex? {
        do {
            return try BookIndex()
        } catch {
            logger.error("failed to open index: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    private static func databaseURL() throws -> URL {
        let appSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = appSupport.appendingPathComponent("com.pdrbrnd.tinta", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("index.db")
    }

    private static var migrator: DatabaseMigrator {
        var m = DatabaseMigrator()

        m.registerMigration("v1") { db in
            try db.create(table: "books") { t in
                t.primaryKey("id", .text)
                t.column("title", .text).notNull()
                t.column("authors_json", .text).notNull()
                t.column("language_code", .text)
                t.column("year", .integer)
                t.column("file_path", .text).notNull()
                t.column("cover_path", .text)
                t.column("date_added", .datetime).notNull()
                t.column("origin", .text).notNull()
            }
        }

        return m
    }
}
