import Foundation
import GRDB
import os

enum BookIndexError: LocalizedError {
    case open(underlying: Error)
    case write(underlying: Error)
    case read(underlying: Error)

    var errorDescription: String? {
        switch self {
        case .open: "Couldn't open the library index."
        case .write: "Couldn't save changes to the library index."
        case .read: "Couldn't read from the library index."
        }
    }
}

actor BookIndex {
    private let pool: DatabasePool

    init() throws(BookIndexError) {
        do {
            let url = try Self.databaseURL()
            indexLogger.info("opening index at \(url.path(percentEncoded: false), privacy: .public)")
            let pool = try DatabasePool(path: url.path(percentEncoded: false))
            try Self.migrator.migrate(pool)
            self.pool = pool
        } catch {
            throw BookIndexError.open(underlying: error)
        }
    }

    func add(_ book: Book) async throws {
        let authorsJson = try Self.encodeJSON(book.authors)
        try await pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO books (id, title, authors_json, locale, year, file_path, cover_path, date_added)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
                ]
            )
        }
    }

    /// Inserts many books in a single write transaction. Used by batch import
    /// to avoid one transaction (and one full reload) per file. Mirrors the
    /// INSERT in `add`; callers reload once after the whole batch.
    func addBooks(_ books: [Book]) async throws {
        guard !books.isEmpty else { return }
        let rows = try books.map { ($0, try Self.encodeJSON($0.authors)) }
        try await pool.write { db in
            for (book, authorsJson) in rows {
                try db.execute(
                    sql: """
                        INSERT INTO books (id, title, authors_json, locale, year, file_path, cover_path, date_added)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
                    ]
                )
            }
        }
    }

    func all() async throws -> [Book] {
        try await pool.read { db in
            let bookRows = try Row.fetchAll(db, sql: "SELECT * FROM books ORDER BY date_added DESC")
            let memberships = try Row.fetchAll(
                db, sql: "SELECT book_id, collection_id FROM book_collections")
            var byBook: [String: Set<UUID>] = [:]
            for row in memberships {
                guard
                    let bookID: String = row["book_id"],
                    let collIDStr: String = row["collection_id"],
                    let collID = UUID(uuidString: collIDStr)
                else { continue }
                byBook[bookID, default: []].insert(collID)
            }
            return bookRows.compactMap { row in
                guard var book = Self.book(from: row) else { return nil }
                book.collectionIDs = byBook[book.id.uuidString] ?? []
                return book
            }
        }
    }

    // MARK: - Collections

    func collections() async throws -> [Collection] {
        try await pool.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT * FROM collections ORDER BY sort_order ASC, date_created ASC")
            return rows.compactMap { Self.collection(from: $0) }
        }
    }

    /// Wipes the `collections` and `book_collections` tables, then inserts
    /// the given definitions verbatim (preserving their UUIDs and sortOrder).
    /// Called at the start of every disk sync — `.tomo/collections.json` is
    /// the source of truth, the index is just a queryable mirror.
    func seedCollections(_ collections: [Collection]) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM book_collections")
            try db.execute(sql: "DELETE FROM collections")
            for collection in collections {
                try Self.insertCollection(collection, into: db)
            }
        }
    }

    /// Returns the existing collection with `name` (case-insensitive), or
    /// creates one if none exists. Used by rebuild-from-sidecars.
    func getOrCreateCollection(named name: String) async throws -> Collection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await pool.write { db in
            if let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM collections WHERE LOWER(name) = LOWER(?) LIMIT 1",
                arguments: [trimmed]
            ),
                let existing = Self.collection(from: row)
            {
                return existing
            }
            let nextSort =
                try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM collections") ?? 0
            let collection = Collection(
                id: UUID(),
                name: trimmed,
                sortOrder: nextSort,
                dateCreated: Date()
            )
            try Self.insertCollection(collection, into: db)
            return collection
        }
    }

    func createCollection(named name: String) async throws -> Collection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return try await pool.write { db in
            let nextSort =
                try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sort_order), -1) + 1 FROM collections") ?? 0
            let collection = Collection(
                id: UUID(),
                name: trimmed,
                sortOrder: nextSort,
                dateCreated: Date()
            )
            try Self.insertCollection(collection, into: db)
            return collection
        }
    }

    func renameCollection(id: UUID, to newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        try await pool.write { db in
            try db.execute(
                sql: "UPDATE collections SET name = ? WHERE id = ?",
                arguments: [trimmed, id.uuidString]
            )
        }
    }

    func deleteCollection(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(sql: "DELETE FROM collections WHERE id = ?", arguments: [id.uuidString])
            // book_collections rows cascade.
        }
    }

    func addBook(_ bookID: UUID, to collectionID: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "INSERT OR IGNORE INTO book_collections (book_id, collection_id) VALUES (?, ?)",
                arguments: [bookID.uuidString, collectionID.uuidString]
            )
        }
    }

    func removeBook(_ bookID: UUID, from collectionID: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM book_collections WHERE book_id = ? AND collection_id = ?",
                arguments: [bookID.uuidString, collectionID.uuidString]
            )
        }
    }

    func delete(_ book: Book) async throws {
        try await delete(id: book.id)
    }

    func delete(id: UUID) async throws {
        try await pool.write { db in
            try db.execute(
                sql: "DELETE FROM books WHERE id = ?",
                arguments: [id.uuidString]
            )
        }
    }

    /// Slim variant of `all()` for reconciliation — avoids decoding rows when
    /// we only need to diff identity sets.
    func allIDs() async throws -> Set<UUID> {
        try await pool.read { db in
            let strings = try String.fetchAll(db, sql: "SELECT id FROM books")
            return Set(strings.compactMap(UUID.init))
        }
    }

    func update(_ book: Book) async throws {
        let authorsJson = try Self.encodeJSON(book.authors)
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
                            date_added = ?
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
        let dir = appSupport.appendingPathComponent("com.pdrbrnd.tomo", isDirectory: true)
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
            try db.alter(table: "books") { t in
                t.add(column: "locale", .text).notNull().defaults(to: "und")
                t.add(column: "locale_confidence", .double)
            }
            try db.execute(
                sql: """
                    UPDATE books SET
                            locale = COALESCE(language_profile_id, language_code, 'und'),
                            locale_confidence = language_confidence
                    """)
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

        m.registerMigration("v5_collections") { db in
            try db.create(table: "collections") { t in
                t.primaryKey("id", .text)
                t.column("name", .text).notNull()
                t.column("sort_order", .integer).notNull()
                t.column("date_created", .datetime).notNull()
            }
            try db.create(table: "book_collections") { t in
                t.column("book_id", .text)
                    .notNull()
                    .references("books", column: "id", onDelete: .cascade)
                t.column("collection_id", .text)
                    .notNull()
                    .references("collections", column: "id", onDelete: .cascade)
                t.primaryKey(["book_id", "collection_id"])
            }
            try db.create(
                index: "idx_book_collections_collection",
                on: "book_collections",
                columns: ["collection_id"]
            )
        }

        // `origin` (BookOrigin) was a vestigial field: stored in every sidecar
        // and DB row but only read to render a single inspector label.
        // Removed wholesale. Old sidecars still carry the field — Codable
        // ignores unknown keys so they decode cleanly and the field falls
        // away on the next write.
        m.registerMigration("v6_drop_origin") { db in
            try db.alter(table: "books") { t in
                t.drop(column: "origin")
            }
        }

        return m
    }

    private static func insertCollection(_ collection: Collection, into db: Database) throws {
        try db.execute(
            sql: """
                INSERT INTO collections (id, name, sort_order, date_created)
                VALUES (?, ?, ?, ?)
                """,
            arguments: [
                collection.id.uuidString,
                collection.name,
                collection.sortOrder,
                collection.dateCreated,
            ]
        )
    }

    private static func collection(from row: Row) -> Collection? {
        let idString: String? = row["id"]
        let name: String? = row["name"]
        let sortOrder: Int? = row["sort_order"]
        let dateCreated: Date? = row["date_created"]

        guard
            let idString,
            let id = UUID(uuidString: idString),
            let name,
            let sortOrder,
            let dateCreated
        else { return nil }

        return Collection(id: id, name: name, sortOrder: sortOrder, dateCreated: dateCreated)
    }

    private static func encodeJSON<T: Encodable>(_ value: T) throws -> String {
        // UTF-8 decoding of JSONEncoder output cannot fail.
        let data = try JSONEncoder().encode(value)
        return String(decoding: data, as: UTF8.self)
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

        guard
            let idString,
            let id = UUID(uuidString: idString),
            let title,
            let authorsJson,
            let authors = decodeJSON(authorsJson, as: [String].self),
            let filePath,
            let dateAdded
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
            fileURL: URL(fileURLWithPath: filePath)
        )
    }
}
