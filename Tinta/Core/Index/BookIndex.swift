import Foundation
import GRDB
import os

actor BookIndex {
    private let pool: DatabasePool

    init() throws {
        let url = try Self.databaseURL()
        indexLogger.info("opening index at \(url.path(percentEncoded: false), privacy: .public)")
        let pool = try DatabasePool(path: url.path(percentEncoded: false))
        try Self.migrator.migrate(pool)
        self.pool = pool
    }

    static func open() -> BookIndex? {
        do {
            return try BookIndex()
        } catch {
            indexLogger.error("failed to open index: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    func add(_ book: Book) async throws {
        let authorsJson = try Self.encodeJSON(book.authors)
        let originJson = try Self.encodeJSON(book.origin)
        try await pool.write { db in
            try db.execute(
                sql: """
                INSERT INTO books (id, title, authors_json, locale, year, file_path, cover_path, date_added, origin)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    book.id.uuidString,
                    book.title,
                    authorsJson,
                    book.locale,
                    book.year,
                    book.fileURL.path(percentEncoded: false),
                    book.coverPath,
                    book.dateAdded,
                    originJson,
                ]
            )
        }
    }

    func all() async throws -> [Book] {
        try await pool.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT * FROM books ORDER BY date_added DESC")
            return rows.compactMap { Self.book(from: $0) }
        }
    }

    func wipeAll() async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM books")
        }
    }

    func delete(_ book: Book) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM books WHERE id = ?",
                arguments: [book.id.uuidString]
            )
        }
    }

    func update(_ book: Book) async throws {
        let authorsJson = try Self.encodeJSON(book.authors)
        let originJson = try Self.encodeJSON(book.origin)
        try await pool.write { db in
            try db.execute(
                sql: """
                UPDATE books SET
                    title = ?,
                    authors_json = ?,
                    locale = ?,
                    year = ?,
                    file_path = ?,
                    cover_path = ?,
                    date_added = ?,
                    origin = ?
                WHERE id = ?
                """,
                arguments: [
                    book.title,
                    authorsJson,
                    book.locale,
                    book.year,
                    book.fileURL.path(percentEncoded: false),
                    book.coverPath,
                    book.dateAdded,
                    originJson,
                    book.id.uuidString,
                ]
            )
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

        m.registerMigration("v2_language_profile") { db in
            try db.alter(table: "books") { t in
                t.add(column: "language_profile_id", .text)
                t.add(column: "language_confidence", .double)
            }
        }

        m.registerMigration("v3_unified_locale") { db in
            // Add new columns
            try db.alter(table: "books") { t in
                t.add(column: "locale", .text).notNull().defaults(to: "und")
                t.add(column: "locale_confidence", .double)
            }
            // Backfill from old columns
            try db.execute(sql: """
                UPDATE books SET
                    locale = COALESCE(language_profile_id, language_code, 'und'),
                    locale_confidence = language_confidence
                """)
            // Drop old columns
            try db.alter(table: "books") { t in
                t.drop(column: "language_code")
                t.drop(column: "language_profile_id")
                t.drop(column: "language_confidence")
            }
        }

        m.registerMigration("v4_drop_locale_confidence") { db in
            try db.alter(table: "books") { t in
                t.drop(column: "locale_confidence")
            }
        }

        return m
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        let data = try JSONEncoder().encode(value)
        return String(data: data, encoding: .utf8) ?? "null"
    }

    private static func decodeJSON<T: Decodable>(_ string: String, as type: T.Type) -> T? {
        guard let data = string.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    private static func book(from row: Row) -> Book? {
        let idString: String? = row["id"]
        let title: String? = row["title"]
        let authorsJson: String? = row["authors_json"]
        let filePath: String? = row["file_path"]
        let dateAdded: Date? = row["date_added"]
        let originJson: String? = row["origin"]

        guard
            let idString,
            let id = UUID(uuidString: idString),
            let title,
            let authorsJson,
            let authors = decodeJSON(authorsJson, as: [String].self),
            let filePath,
            let dateAdded,
            let originJson,
            let origin = decodeJSON(originJson, as: BookOrigin.self)
        else {
            indexLogger.error("dropping malformed row id=\(idString ?? "?", privacy: .public)")
            return nil
        }

        let locale: String = row["locale"] ?? "und"
        let year: Int? = row["year"]
        let coverPath: String? = row["cover_path"]

        return Book(
            id: id,
            title: title,
            authors: authors,
            year: year,
            locale: locale,
            coverPath: coverPath,
            dateAdded: dateAdded,
            fileURL: URL(fileURLWithPath: filePath),
            origin: origin
        )
    }
}
